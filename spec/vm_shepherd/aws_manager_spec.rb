require 'vm_shepherd/aws_manager'

module VmShepherd
  RSpec.describe AwsManager do
    let(:access_key) { 'access-key' }
    let(:secret_key) { 'secret-key' }
    let(:ami_id) { 'ami-deadbeef' }
    let(:ami_file_path) do
      Tempfile.new('ami-id-file').tap do |f|
        f.write("#{{'us-east-1' => ami_id, 'not-the-right-region' => 'bad-id'}.to_yaml}")
        f.close
      end.path
    end
    let(:elastic_ip_id) { 'elastic-ip-id' }
    let(:ec2) { double('AWS.ec2') }

    let(:env_config) do
      {
        stack_name: 'aws-stack-name',
        aws_access_key: 'aws-access-key',
        aws_secret_key: 'aws-secret-key',
        region: 'us-east-1',
        json_file: 'cloudformation.json',
        parameters: {
          'some_parameter' => 'some-answer',
        },
        outputs: {
          ssh_key_name: 'ssh-key-name',
          security_group: 'security-group-id',
          public_subnet_id: 'public-subnet-id',
          private_subnet_id: 'private-subnet-id',
        }.merge(extra_outputs),
      }.merge(extra_configs)
    end

    let(:extra_outputs) { {} }
    let(:extra_configs) { {} }

    let(:vm_config) do
      {
        vm_name: 'some-vm-name',
      }
    end
    let(:fake_logger) { instance_double(Logger).as_null_object }

    subject(:ami_manager) { AwsManager.new(env_config: env_config, logger: fake_logger) }

    before do
      expect(AWS).to receive(:config).with(
          access_key_id: env_config.fetch(:aws_access_key),
          secret_access_key: env_config.fetch(:aws_secret_key),
          region: env_config.fetch(:region),
        )

      allow(AWS).to receive(:ec2).and_return(ec2)
      allow(ami_manager).to receive(:sleep) # speed up retry logic
    end

    describe '#prepare_environment' do
      let(:cloudformation_template_file) { Tempfile.new('cloudformation_template_file').tap { |f| f.write('{}'); f.close } }
      let(:cfm) { instance_double(AWS::CloudFormation, stacks: stack_collection) }
      let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'CREATE_COMPLETE') }
      let(:stack_collection) { instance_double(AWS::CloudFormation::StackCollection) }
      let(:elb) { instance_double(AWS::ELB, client: elb_client) }
      let(:elb_client) { double(AWS::ELB::Client) }

      before do
        allow(AWS::CloudFormation).to receive(:new).and_return(cfm)
        allow(AWS::ELB).to receive(:new).and_return(elb)
        allow(stack_collection).to receive(:create).and_return(stack)
      end

      describe 'cloudformation' do
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
              exactly(30).times

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

      context 'when the elb setting is present' do
        let(:extra_configs) do
          {
            elbs: [
                    {
                      name: 'elb-1-name',
                      port_mappings: [[1111, 11]],
                      stack_output_keys: {
                        vpc_id: 'vpc_id',
                        subnet_id: 'private_subnet',
                      },
                    },
                    {
                      name: 'elb-2-name',
                      port_mappings: [[2222, 22]],
                      stack_output_keys: {
                        vpc_id: 'vpc_id',
                        subnet_id: 'private_subnet',
                      },
                    }
                  ],
          }
        end
        let(:stack) do
          instance_double(AWS::CloudFormation::Stack,
            name: 'fake-stack-name',
            creation_time: Time.utc(2015, 5, 29),
            status: 'CREATE_COMPLETE',
            outputs: stack_outputs
          )
        end
        let(:stack_outputs) do
          [
            instance_double(AWS::CloudFormation::StackOutput, key: 'private_subnet', value: 'fake-subnet-id'),
            instance_double(AWS::CloudFormation::StackOutput, key: 'vpc_id', value: 'fake-vpc-id'),
          ]
        end
        let(:ec2_client) { double(AWS::EC2::Client) }
        let(:create_security_group_response) do
          {:group_id => 'elb-security-group'}
        end
        let(:security_groups) do
          {
            'elb-security-group' => elb_security_group,
          }
        end
        let(:elb_security_group) { instance_double(AWS::EC2::SecurityGroup, security_group_id: 'elb-security-group-id') }

        before do
          allow(ec2).to receive(:client).and_return(ec2_client)
          allow(ec2_client).to receive(:create_security_group).and_return(create_security_group_response)
          allow(ec2).to receive(:security_groups).and_return(security_groups)
          allow(elb_security_group).to receive(:authorize_ingress)
          allow(elb_client).to receive(:create_load_balancer)
        end

        it 'creates and attaches a security group for the first ELB' do
          security_group_args = {
            group_name: 'fake-stack-name_elb-1-name',
            description: 'ELB Security Group',
            vpc_id: 'fake-vpc-id',
          }
          expect(ec2_client).to receive(:create_security_group).with(security_group_args).and_return(create_security_group_response)
          expect(elb_security_group).to receive(:authorize_ingress).with(:tcp, 1111, '0.0.0.0/0')

          ami_manager.prepare_environment(cloudformation_template_file.path)
        end

        it 'attaches an elb with the name of the stack for the first ELB' do
          elb_params = {
            load_balancer_name: 'elb-1-name',
            listeners: [
              {protocol: 'TCP', load_balancer_port: 1111, instance_protocol: 'TCP', instance_port: 11},
            ],
            subnets: ['fake-subnet-id'],
            security_groups: ['elb-security-group-id']
          }
          expect(elb_client).to receive(:create_load_balancer).with(elb_params)

          ami_manager.prepare_environment(cloudformation_template_file.path)
        end

        it 'creates and attaches a security group for the second ELB' do
          security_group_args = {
            group_name: 'fake-stack-name_elb-2-name',
            description: 'ELB Security Group',
            vpc_id: 'fake-vpc-id',
          }
          expect(ec2_client).to receive(:create_security_group).with(security_group_args).and_return(create_security_group_response)
          expect(elb_security_group).to receive(:authorize_ingress).with(:tcp, 2222, '0.0.0.0/0')

          ami_manager.prepare_environment(cloudformation_template_file.path)
        end

        it 'attaches an elb with the name of the stack for the second ELB' do
          elb_params = {
            load_balancer_name: 'elb-2-name',
            listeners: [
              {protocol: 'TCP', load_balancer_port: 2222, instance_protocol: 'TCP', instance_port: 22},
            ],
            subnets: ['fake-subnet-id'],
            security_groups: ['elb-security-group-id']
          }
          expect(elb_client).to receive(:create_load_balancer).with(elb_params)

          ami_manager.prepare_environment(cloudformation_template_file.path)
        end
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

      context 'vm configuration does not contain an elastic IP' do
        it 'creates and attaches an elastic IP' do
          expect(ec2).to receive_message_chain(:elastic_ips, :create).with(
            vpc: true).and_return(elastic_ip)

          expect(instance).to receive(:associate_elastic_ip).with(elastic_ip)

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end
      end

      context 'vm configuration contains an elastic IP' do
        let(:vm_config) do
          {
            vm_name: 'some-vm-name',
            vm_ip_address: 'some-ip-address'
          }
        end

        it 'attaches the provided ip address to the VM' do
          expect(AWS::EC2::ElasticIp).to receive(:new).and_return(elastic_ip)
          expect(instance).to receive(:associate_elastic_ip).with(elastic_ip)

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end
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
      let(:instance1) { instance_double(AWS::EC2::Instance, tags: {}, id: 'instance1') }
      let(:instance2) { instance_double(AWS::EC2::Instance, tags: {}, id: 'instance2') }
      let(:subnet1_instances) { [instance1] }
      let(:subnet2_instances) { [instance2] }
      let(:cfm) { instance_double(AWS::CloudFormation, stacks: stack_collection) }
      let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'DELETE_COMPLETE', delete: nil) }
      let(:stack_collection) { instance_double(AWS::CloudFormation::StackCollection) }

      let(:instance1_volume) { instance_double(AWS::EC2::Volume, id: 'volume-id') }
      let(:instance1_attachment) do
        instance_double(AWS::EC2::Attachment, volume: instance1_volume, delete_on_termination: true)
      end

      let(:buckets) { instance_double(AWS::S3::BucketCollection) }
      let(:s3_client) { instance_double(AWS::S3, buckets: buckets) }

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

        allow(AWS::S3).to receive(:new).and_return(s3_client)
        allow(buckets).to receive(:[]).and_return(instance_double(AWS::S3::Bucket, exists?: false))
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
            exactly(30).times

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

      it 'when an elb is not configured' do
        expect(AWS::ELB).not_to receive(:new)
        ami_manager.clean_environment
      end

      it 'when there is no s3 bucket configuration' do
        expect_any_instance_of(AWS::S3::Bucket).not_to receive(:clear!)
        ami_manager.clean_environment
      end

      it 'does not look up buckets when there is no name' do
        expect(buckets).to_not receive(:[])
        ami_manager.clean_environment
      end

      context 'when a subnet is not provided' do
        before do
          env_config[:outputs][:private_subnet_id] = nil
        end

        it 'only deletes instance 1' do
          expect(instance1).to receive(:terminate)
          expect(instance2).not_to receive(:terminate)

          ami_manager.clean_environment
        end
      end

      context 'when an elb is configured' do
        let(:extra_configs) do
          {
            elb: {
              name: 'elb-name',
              stack_output_keys: {
                subnet_id: 'private_subnet',
              },
            },
          }
        end

        let(:elb) { instance_double(AWS::ELB, load_balancers: [load_balancer_to_delete, other_load_balancer]) }
        let(:load_balancer_to_delete) do
          instance_double(AWS::ELB::LoadBalancer,
            name: 'elb-name',
            security_groups: [elb_security_group],
            exists?: false,
          )
        end
        let(:other_load_balancer) { instance_double(AWS::ELB::LoadBalancer, name: 'other-elb-name') }
        let(:elb_security_group) { instance_double(AWS::EC2::SecurityGroup, name: 'elb-security-group', id: 'sg-id') }
        let(:network_interface_1) do
          instance_double(AWS::EC2::NetworkInterface,
            security_groups: [elb_security_group],
            exists?: false,
          )
        end
        let(:network_interface_2) do
          instance_double(AWS::EC2::NetworkInterface,
            security_groups: [elb_security_group],
            exists?: false,
          )
        end

        before do
          allow(AWS::ELB).to receive(:new).and_return(elb)
          allow(ec2).to receive(:network_interfaces).and_return([network_interface_1, network_interface_2])
          allow(load_balancer_to_delete).to receive(:delete)
          allow(elb_security_group).to receive(:delete)
        end

        it 'waits for the elb to be deleted' do
          expect(load_balancer_to_delete).to receive(:exists?).and_return(true).
              exactly(10).times

          expect(elb_security_group).not_to receive(:delete).ordered
          expect { ami_manager.clean_environment }.to raise_error(AwsManager::RetryLimitExceeded)
        end

        it 'waits for the network interfaces to be deleted' do
          allow(load_balancer_to_delete).to receive(:exists?).and_return(false)

          expect(network_interface_1).to receive(:exists?).and_return(false).
              exactly(10).times

          expect(network_interface_2).to receive(:exists?).and_return(true).
              exactly(10).times

          expect(elb_security_group).not_to receive(:delete).ordered
          expect { ami_manager.clean_environment }.to raise_error(AwsManager::RetryLimitExceeded)
        end

        it 'terminates the ELB then removes the security group' do
          expect(load_balancer_to_delete).to receive(:delete).ordered
          expect(elb_security_group).to receive(:delete).ordered

          ami_manager.clean_environment
        end

        it 'leaves unknown ELBs alone' do
          expect(other_load_balancer).not_to receive(:delete)

          ami_manager.clean_environment
        end

        context 'when the ELB does not exist' do
          let(:elb) { instance_double(AWS::ELB, load_balancers: []) }

          it 'does not throw an error' do
            expect { ami_manager.clean_environment }.not_to raise_error
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
          end

          it 'retries the delete' do
            ami_manager.clean_environment
          end
        end
      end

      context 'when there is an s3 bucket configuration' do
        let(:bucket) { instance_double(AWS::S3::Bucket) }
        let(:extra_outputs) { {s3_bucket_name: bucket_name} }
        let(:bucket_name) { 'bucket-name' }

        before { allow(buckets).to receive(:[]).with(bucket_name).and_return(bucket) }

        context 'and the bucket does exist' do
          before { allow(bucket).to receive(:exists?).and_return(true) }

          it 'clears the bucket' do
            expect(bucket).to receive(:clear!)
            ami_manager.clean_environment
          end
        end

        context 'and the bucket does not exist' do
          before { allow(bucket).to receive(:exists?).and_return(false) }

          it 'fails silently' do
            expect(bucket).not_to receive(:clear!)
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
