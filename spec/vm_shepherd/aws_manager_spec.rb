require 'vm_shepherd/aws_manager'

module VmShepherd
  RSpec.describe AwsManager do
    let(:access_key) { 'access-key' }
    let(:secret_key) { 'secret-key' }
    let(:ami_id) { 'ami-deadbeef' }
    let(:ami_file_path) { Tempfile.new('ami-id-file').tap { |f| f.write("#{ami_id}\n"); f.close }.path }
    let(:elastic_ip_id) { 'elastic-ip-id' }
    let(:ec2) { double('AWS.ec2') }

    let(:env_config) do
      {
        stack_name: 'aws-stack-name',
        aws_access_key: 'aws-access-key',
        aws_secret_key: 'aws-secret-key',
        json_file: 'cloudformation.json',
        parameters: {
          'some_parameter' => 'some-answer',
        },
        outputs: {
          ssh_key_name: 'ssh-key-name',
          security_group: 'security-group-id',
          public_subnet_id: 'public-subnet-id',
          private_subnet_id: 'private-subnet-id',
        },
      }
    end

    let(:vm_config) do
      {
        vm_name: 'some-vm-name',
      }
    end

    subject(:ami_manager) { AwsManager.new(env_config) }

    before do
      expect(AWS).to receive(:config).with(
          access_key_id: env_config.fetch(:aws_access_key),
          secret_access_key: env_config.fetch(:aws_secret_key),
          region: 'us-east-1',
        )

      allow(AWS).to receive(:ec2).and_return(ec2)
      allow(ami_manager).to receive(:sleep) # speed up retry logic
    end

    describe '#prepare_environment' do
      let(:cloudformation_template_file) { Tempfile.new('cloudformation_template_file').tap { |f| f.write('{}'); f.close } }
      let(:cfm) { instance_double(AWS::CloudFormation, stacks: stack_collection) }
      let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'CREATE_COMPLETE') }
      let(:stack_collection) { instance_double(AWS::CloudFormation::StackCollection) }

      before do
        allow(AWS::CloudFormation).to receive(:new).and_return(cfm)
        allow(stack_collection).to receive(:create).and_return(stack)
      end

      it 'creates the stack with the correct parameters' do
        expect(stack_collection).to receive(:create).with(
            'aws-stack-name',
            '{}',
            parameters: {
              'some_parameter' => 'some-answer',
            },
            capabilities: ['CAPABILITY_IAM']
          )
        ami_manager.prepare_environment(cloudformation_template_file.path)
      end

      it 'waits for the stack to finish creating' do
        expect(stack).to receive(:status).and_return('CREATE_IN_PROGRESS', 'CREATE_IN_PROGRESS', 'CREATE_IN_PROGRESS', 'CREATE_COMPLETE')

        ami_manager.prepare_environment(cloudformation_template_file.path)
      end

      it 'stops retrying after 360 times' do
        expect(stack).to receive(:status).and_return('CREATE_IN_PROGRESS').
            exactly(360).times

        expect { ami_manager.prepare_environment(cloudformation_template_file.path) }.to raise_error(AwsManager::RetryLimitExceeded)
      end

      it 'aborts if stack fails to create' do
        expect(stack).to receive(:status).and_return('CREATE_IN_PROGRESS', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_COMPLETE').ordered
        expect(stack).to receive(:delete)
        expect {
          ami_manager.prepare_environment(cloudformation_template_file.path)
        }.to raise_error('Unexpected status for stack aws-stack-name : ROLLBACK_COMPLETE')
      end
    end

    describe '#deploy' do
      let(:instance) { instance_double(AWS::EC2::Instance, status: :running, associate_elastic_ip: nil, add_tag: nil) }
      let(:elastic_ip) { instance_double(AWS::EC2::ElasticIp, allocation_id: 'allocation-id') }
      let(:instances) { instance_double(AWS::EC2::InstanceCollection, create: instance) }
      let(:elastic_ips) { instance_double(AWS::EC2::ElasticIpCollection, create: elastic_ip) }

      before do
        allow(ec2).to receive(:instances).and_return(instances)
        allow(ec2).to receive(:elastic_ips).and_return(elastic_ips)
      end

      it 'creates an instance using AWS SDK v1' do
        expect(ec2).to receive_message_chain(:instances, :create).with(
            image_id: ami_id,
            key_name: 'ssh-key-name',
            security_group_ids: ['security-group-id'],
            subnet: 'public-subnet-id',
            instance_type: 'm3.medium').and_return(instance)

        ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
      end

      context 'when the ip address is in use' do
        it 'retries until the IP address is available' do
          expect(instances).to receive(:create).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse).once
          expect(instances).to receive(:create).and_return(instance).once

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end

        it 'stops retrying after 60 times' do
          expect(instances).to receive(:create).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse).
              exactly(AwsManager::RETRY_LIMIT).times

          expect { ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config) }.to raise_error(AwsManager::RetryLimitExceeded)
        end
      end

      it 'does not return until the instance is running' do
        expect(instance).to receive(:status).and_return(:pending, :pending, :pending, :running)

        ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
      end

      it 'handles API endpoints not knowing (right away) about the instance created' do
        expect(instance).to receive(:status).and_raise(AWS::EC2::Errors::InvalidInstanceID::NotFound).
            exactly(AwsManager::RETRY_LIMIT - 1).times
        expect(instance).to receive(:status).and_return(:running).once

        ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
      end

      it 'stops retrying after 60 times' do
        expect(instance).to receive(:status).and_return(:pending).
            exactly(AwsManager::RETRY_LIMIT).times

        expect { ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config) }.to raise_error(AwsManager::RetryLimitExceeded)
      end

      it 'creates and attaches an elastic IP' do
        expect(ec2).to receive_message_chain(:elastic_ips, :create).with(
            vpc: true).and_return(elastic_ip)

        expect(instance).to receive(:associate_elastic_ip).with(elastic_ip.allocation_id)

        ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
      end

      it 'tags the instance with a name' do
        expect(instance).to receive(:add_tag).with('Name', value: 'some-vm-name')

        ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
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
      let(:cfm) { instance_double(AWS::CloudFormation, stacks: stack_collection) }
      let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'DELETE_COMPLETE', delete: nil) }
      let(:stack_collection) { instance_double(AWS::CloudFormation::StackCollection) }

      let(:instance1_volume) { instance_double(AWS::EC2::Volume) }
      let(:instance1_attachment) do
        instance_double(AWS::EC2::Attachment, volume: instance1_volume, delete_on_termination: true)
      end

      before do
        allow(AWS::CloudFormation).to receive(:new).and_return(cfm)
        allow(stack_collection).to receive(:[]).and_return(stack)

        allow(ec2).to receive(:subnets).and_return(subnets)
        allow(subnets).to receive(:[]).with('public-subnet-id').and_return(subnet1)
        allow(subnets).to receive(:[]).with('private-subnet-id').and_return(subnet2)

        allow(instance1).to receive(:attachments).and_return({'/dev/test' => instance1_attachment})
        allow(instance2).to receive(:attachments).and_return({})

        allow(instance1).to receive(:terminate)
        allow(instance2).to receive(:terminate)
      end

      it 'terminates all VMs in the subnet' do
        expect(instance1).to receive(:terminate)
        expect(instance2).to receive(:terminate)

        ami_manager.clean_environment
      end

      it 'deletes the stack' do
        expect(stack_collection).to receive(:[]).with('aws-stack-name').and_return(stack)
        expect(stack).to receive(:delete)
        ami_manager.clean_environment
      end

      it 'waits for stack deletion to complete' do
        expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS', 'DELETE_IN_PROGRESS', 'DELETE_IN_PROGRESS', 'DELETE_COMPLETE')

        ami_manager.clean_environment
      end

      it 'stops retrying after 360 times' do
        expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS').
            exactly(360).times

        expect { ami_manager.clean_environment }.to raise_error(AwsManager::RetryLimitExceeded)
      end

      it 'aborts if stack reports unexpected status' do
        expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS', 'UNEXPECTED_STATUS').ordered
        expect {
          ami_manager.clean_environment
        }.to raise_error('Unexpected status for stack aws-stack-name : UNEXPECTED_STATUS')
      end

      it 'aborts if stack throws error' do
        expect(stack).to receive(:status).and_raise(AWS::CloudFormation::Errors::ValidationError)
        allow(stack).to receive(:exists?).and_return(true)
        expect {
          ami_manager.clean_environment
        }.to raise_error(AWS::CloudFormation::Errors::ValidationError)
      end

      it 'succeeds if stack throws error and stack deletion has completed' do
        expect(stack).to receive(:status).and_raise(AWS::CloudFormation::Errors::ValidationError)
        allow(stack).to receive(:exists?).and_return(false)
        expect {
          ami_manager.clean_environment
        }.not_to raise_error
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
      let(:elastic_ip) { nil }
      let(:instance) { instance_double(AWS::EC2::Instance, tags: {'Name' => 'some-vm-name'}, elastic_ip: elastic_ip) }
      let(:non_terminated_instance) { instance_double(AWS::EC2::Instance, tags: {}) }
      let(:instances) { [non_terminated_instance, instance] }

      before do
        allow(ec2).to receive(:instances).and_return(instances)
        allow(instance).to receive(:terminate)
      end

      it 'terminates the VM with the specified name' do
        expect(non_terminated_instance).not_to receive(:terminate)
        expect(instance).to receive(:terminate)

        ami_manager.destroy(vm_config)
      end

      context 'when there is an elastic ip' do
        let(:elastic_ip) { instance_double(AWS::EC2::ElasticIp) }

        before do
          allow(elastic_ip).to receive(:delete)
          allow(elastic_ip).to receive(:disassociate)
        end

        it 'terminates the VM with the specified name' do
          expect(non_terminated_instance).not_to receive(:terminate)
          expect(instance).to receive(:terminate)

          ami_manager.destroy(vm_config)
        end

        it 'disassociates and deletes the ip associated with the terminated vm' do
          expect(elastic_ip).to receive(:disassociate).ordered
          expect(elastic_ip).to receive(:delete).ordered

          ami_manager.destroy(vm_config)
        end
      end
    end
  end
end
