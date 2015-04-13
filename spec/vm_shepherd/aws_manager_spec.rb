require 'vm_shepherd/aws_manager'

module VmShepherd
  RSpec.describe AwsManager do
    let(:access_key) { 'access-key' }
    let(:secret_key) { 'secret-key' }
    let(:ami_id) { 'ami-deadbeef' }
    let(:ami_file_path) { Tempfile.new('ami-id-file').tap { |f| f.write("#{ami_id}\n"); f.close }.path }
    let(:elastic_ip_id) { 'elastic-ip-id' }
    let(:ec2) { double('AWS.ec2') }

    let(:aws_options) do
      {
        aws_access_key: 'aws-access-key',
        aws_secret_key: 'aws-secret-key',
        ssh_key_name: 'ssh-key-name',
        security_group_id: 'security-group-id',
        public_subnet_id: 'public-subnet-id',
        private_subnet_id: 'private-subnet-id',
        elastic_ip_id: elastic_ip_id,
        vm_name: 'Ops Manager: clean_install_spec'
      }
    end

    subject(:ami_manager) { AwsManager.new(aws_options) }

    before do
      expect(AWS).to receive(:config).with(
          access_key_id: aws_options.fetch(:aws_access_key),
          secret_access_key: aws_options.fetch(:aws_secret_key),
          region: 'us-east-1',
        )

      allow(AWS).to receive(:ec2).and_return(ec2)
    end

    describe '#deploy' do
      let(:instance) { instance_double(AWS::EC2::Instance, status: :running, associate_elastic_ip: nil, add_tag: nil) }
      let(:instances) { instance_double(AWS::EC2::InstanceCollection, create: instance) }

      before do
        allow(ec2).to receive(:instances).and_return(instances)
        allow(ami_manager).to receive(:sleep) # speed up retry logic
      end

      it 'creates an instance using AWS SDK v1' do
        expect(ec2).to receive_message_chain(:instances, :create).with(
            image_id: ami_id,
            key_name: 'ssh-key-name',
            security_group_ids: ['security-group-id'],
            subnet: aws_options.fetch(:public_subnet_id),
            instance_type: 'm3.medium').and_return(instance)

        ami_manager.deploy(ami_file_path)
      end

      context 'when the ip address is in use' do
        it 'retries until the IP address is available' do
          expect(instances).to receive(:create).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse).once
          expect(instances).to receive(:create).and_return(instance).once

          ami_manager.deploy(ami_file_path)
        end

        it 'stops retrying after 60 times' do
          expect(instances).to receive(:create).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse).
              exactly(AwsManager::RETRY_LIMIT).times

          expect { ami_manager.deploy(ami_file_path) }.to raise_error(AwsManager::RetryLimitExceeded)
        end
      end

      it 'does not return until the instance is running' do
        expect(instance).to receive(:status).and_return(:pending, :pending, :pending, :running)

        ami_manager.deploy(ami_file_path)
      end

      it 'handles API endpoints not knowing (right away) about the instance created' do
        expect(instance).to receive(:status).and_raise(AWS::EC2::Errors::InvalidInstanceID::NotFound).
            exactly(AwsManager::RETRY_LIMIT - 1).times
        expect(instance).to receive(:status).and_return(:running).once

        ami_manager.deploy(ami_file_path)
      end

      it 'stops retrying after 60 times' do
        expect(instance).to receive(:status).and_return(:pending).
            exactly(AwsManager::RETRY_LIMIT).times

        expect { ami_manager.deploy(ami_file_path) }.to raise_error(AwsManager::RetryLimitExceeded)
      end

      it 'attaches the elastic IP' do
        expect(instance).to receive(:associate_elastic_ip).with(aws_options.fetch(:elastic_ip_id))

        ami_manager.deploy(ami_file_path)
      end

      it 'tags the instance with a name' do
        expect(instance).to receive(:add_tag).with('Name', value: aws_options.fetch(:vm_name))

        ami_manager.deploy(ami_file_path)
      end
    end

    describe '#clean_environment' do
      let(:subnets) { instance_double(AWS::EC2::SubnetCollection) }
      let(:subnet1) { instance_double(AWS::EC2::Subnet, instances: subnet1_instances) }
      let(:subnet2) { instance_double(AWS::EC2::Subnet, instances: subnet2_instances) }
      let(:instance1) { instance_double(AWS::EC2::Instance, tags: {}) }
      let(:instance2) { instance_double(AWS::EC2::Instance, tags: {}) }
      let(:subnet1_instances) { [instance1] }
      let(:subnet2_instances) { [instance2] }

      let(:instance1_volume) { instance_double(AWS::EC2::Volume)}
      let(:instance1_attachment) do
        instance_double(AWS::EC2::Attachment, volume: instance1_volume, delete_on_termination: true)
      end

      before do
        allow(ec2).to receive(:subnets).and_return(subnets)
        allow(subnets).to receive(:[]).with('public-subnet-id').and_return(subnet1)
        allow(subnets).to receive(:[]).with('private-subnet-id').and_return(subnet2)

        allow(instance1).to receive(:attachments).and_return({'/dev/test' => instance1_attachment})
        allow(instance2).to receive(:attachments).and_return({})
      end

      it 'terminates all VMs in the subnet' do
        expect(instance1).to receive(:terminate)
        expect(instance2).to receive(:terminate)

        ami_manager.clean_environment
      end

      context 'when an instance has the magical tag' do
        let(:persistent_instance) { instance_double(AWS::EC2::Instance, tags: persist_tag) }
        let(:instances) { [instance1, instance2, persistent_instance] }

        context 'when the do not terminate tag is present' do
          let(:persist_tag) { { AwsManager::DO_NOT_TERMINATE_TAG_KEY => 'any value' } }
          it 'does not attempt to terminate this instance' do
            expect(instance1).to receive(:terminate)
            expect(instance2).to receive(:terminate)
            expect(persistent_instance).not_to receive(:terminate)

            ami_manager.clean_environment
          end
        end
      end

      context 'when the instance has volumes that are NOT delete_on_termination' do
        let(:instance1_attachment) do
          instance_double(AWS::EC2::Attachment, volume: instance1_volume, delete_on_termination: false)
        end

        before do
          allow(instance1).to receive(:terminate)
          allow(instance2).to receive(:terminate)
        end

        it 'deletes the volumes' do
          expect(instance1_volume).to receive(:delete)

          ami_manager.clean_environment
        end

        context 'when the instance has not finished termination' do
          before do
            expect(instance1_volume).to receive(:delete).and_raise(AWS::EC2::Errors::VolumeInUse)
            expect(instance1_volume).to receive(:delete).and_return(nil)
            allow(ami_manager).to receive(:sleep)
          end

          it 'retries the delete' do
            ami_manager.clean_environment
          end
        end
      end
    end

    describe '#destroy' do
      let(:elastic_ips) { instance_double(AWS::EC2::ElasticIpCollection) }
      let(:elastic_ip) { instance_double(AWS::EC2::ElasticIp, instance: instance, allocation_id: elastic_ip_id) }
      let(:instance) { instance_double(AWS::EC2::Instance, tags: {}) }

      before do
        allow(ec2).to receive(:elastic_ips).and_return(elastic_ips)
        allow(elastic_ips).to receive(:each).and_yield(elastic_ip)
      end

      it 'terminates the VM that matches the IP' do
        expect(instance).to receive(:terminate)

        ami_manager.destroy
      end

      context 'when an instance has the magical tag' do
        let(:persistent_instance) { instance_double(AWS::EC2::Instance, tags: persist_tag) }
        let(:instances) { [instance1, instance2, persistent_instance] }

        context 'when there is no instance attached' do
          before do
            allow(elastic_ip).to receive(:instance).and_return(nil)
          end

          it 'does not explode' do
            ami_manager.destroy
          end
        end
      end
    end
  end
end
