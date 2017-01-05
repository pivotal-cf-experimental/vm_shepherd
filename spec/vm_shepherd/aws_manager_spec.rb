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
        'stack_name' => 'aws-stack-name',
        'aws_access_key' => 'aws-access-key',
        'aws_secret_key' => 'aws-secret-key',
        'region' => 'us-east-1',
        'json_file' => 'cloudformation.json',
        'parameters' => {
          'some_parameter' => 'some-answer',
        },
        'outputs' => {
          'subnets' => ['public-subnet-id', 'private-subnet-id'],
          'security_group' => 'security-group-id',
          'public_subnet_id' => 'public-subnet-id',
        }.merge(extra_outputs),
      }.merge(extra_configs)
    end

    let(:extra_outputs) { {} }
    let(:extra_configs) { {} }

    let(:vm_config) do
      {
        'vm_name' => 'some-vm-name',
        'key_name' => 'ssh-key-name',
      }
    end
    let(:fake_logger) { instance_double(Logger).as_null_object }

    subject(:ami_manager) { AwsManager.new(env_config: env_config, logger: fake_logger) }

    before do
      expect(AWS).to receive(:config).with(
        access_key_id: env_config.fetch('aws_access_key'),
        secret_access_key: env_config.fetch('aws_secret_key'),
        region: env_config.fetch('region'),
      )

      allow(AWS).to receive(:ec2).and_return(ec2)
      allow(ami_manager).to receive(:sleep) # speed up retry logic
    end

    describe '#prepare_environment' do
      let(:cloudformation_template_file) { Tempfile.new('cloudformation_template_file').tap { |f| f.write('{}'); f.close } }
      let(:cfn) { instance_double(AWS::CloudFormation, stacks: stack_collection) }
      let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'CREATE_COMPLETE', update: true, name: 'sample-stack') }

      let(:stack_collection) { instance_double(AWS::CloudFormation::StackCollection) }
      let(:elb) { instance_double(AWS::ELB, load_balancers: load_balancers) }
      let(:load_balancers) { instance_double(AWS::ELB::LoadBalancerCollection) }

      before do
        allow(AWS::CloudFormation).to receive(:new).and_return(cfn)
        allow(AWS::ELB).to receive(:new).and_return(elb)
        allow(stack_collection).to receive(:[]).and_return(nil)
      end

      context 'when a stack already exists' do
        before do
          allow(stack_collection).to receive(:[]).with('aws-stack-name').and_return(stack)
        end

        context 'when update_existing is enabled' do

          let(:extra_configs) { {'update_existing' => true} }
          let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'UPDATE_COMPLETE', update: true, name: 'stack-fails-to-update') }

          it 'upgrades the existing stack with the provided template' do
            ami_manager.prepare_environment(cloudformation_template_file.path)

            expect(stack).to have_received(:update)
          end

          it 'aborts if stack fails to update' do
            expect(stack).to receive(:status).and_return('UPDATE_IN_PROGRESS', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_COMPLETE').ordered
            expect(stack).to receive(:delete)
            expect(stack).to receive(:events).and_return([])
            expect {
              ami_manager.prepare_environment(cloudformation_template_file.path)
            }.to raise_error('Unexpected status for stack aws-stack-name : ROLLBACK_COMPLETE')
          end
        end

        context 'when update_existing is disabled' do
          let(:extra_configs) { {'update_existing' => false} }

          it 'errors out due to the stack already existing' do
            allow(stack_collection).to receive(:create).and_return(stack)

            ami_manager.prepare_environment(cloudformation_template_file.path)

            expect(stack).not_to have_received(:update)
          end
        end
      end

      context 'when the stack does not yet exist' do
        before do
          allow(stack_collection).to receive(:[]).and_return([])
          allow(stack_collection).to receive(:create).and_return(stack)
        end

        describe 'cloudformation' do
          it 'polls the status every 30 seconds' do
            expect(ami_manager).to receive(:retry_until).with(retry_limit: 60, retry_interval: 30)

            ami_manager.prepare_environment(cloudformation_template_file.path)
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

          it 'stops retrying after 80 times' do
            expect(stack).to receive(:status).and_return('CREATE_IN_PROGRESS').
              exactly(60).times

            expect { ami_manager.prepare_environment(cloudformation_template_file.path) }.to raise_error(AwsManager::RetryLimitExceeded)
          end

          it 'aborts if stack fails to create' do
            expect(stack).to receive(:status).and_return('CREATE_IN_PROGRESS', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_COMPLETE').ordered
            expect(stack).to receive(:delete)
            expect(stack).to receive(:name).and_return('dummy')
            expect(stack).to receive(:events).and_return([])
            expect {
              ami_manager.prepare_environment(cloudformation_template_file.path)
            }.to raise_error('Unexpected status for stack aws-stack-name : ROLLBACK_COMPLETE')
          end
        end

        context 'when the elb setting is present' do
          let(:extra_configs) do
            {
              'elbs' => [
                {
                  'name' => 'elb-1-name',
                  'port_mappings' => [[1111, 11]],
                  'health_check' => {
                    'ping_target' => 'TCP:1234',
                  },
                  'stack_output_keys' => {
                    'vpc_id' => 'vpc_id',
                    'subnet_id' => 'private_subnet',
                  },
                },
                {
                  'name' => 'elb-2-name',
                  'port_mappings' => [[2222, 22]],
                  'stack_output_keys' => {
                    'vpc_id' => 'vpc_id',
                    'subnet_id' => 'private_subnet',
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
          let(:create_security_group_response_1) do
            {group_id: 'elb-1-security-group'}
          end
          let(:create_security_group_response_2) do
            {group_id: 'elb-2-security-group'}
          end
          let(:security_groups) do
            {
              'elb-1-security-group' => elb_1_security_group,
              'elb-2-security-group' => elb_2_security_group,
            }
          end
          let(:elb_1_security_group) { instance_double(AWS::EC2::SecurityGroup, security_group_id: 'elb-1-security-group-id') }
          let(:elb_2_security_group) { instance_double(AWS::EC2::SecurityGroup, security_group_id: 'elb-2-security-group-id') }

          let(:elb_1) { instance_double(AWS::ELB::LoadBalancer, configure_health_check: nil) }
          let(:elb_2) { instance_double(AWS::ELB::LoadBalancer) }

          before do
            allow(ec2).to receive(:client).and_return(ec2_client)
            allow(ec2_client).to receive(:create_security_group).with(hash_including(group_name: 'fake-stack-name_elb-1-name')).
              and_return(create_security_group_response_1)
            allow(ec2_client).to receive(:create_security_group).with(hash_including(group_name: 'fake-stack-name_elb-2-name')).
              and_return(create_security_group_response_2)
            allow(ec2).to receive(:security_groups).and_return(security_groups)
            allow(elb_1_security_group).to receive(:authorize_ingress)
            allow(elb_2_security_group).to receive(:authorize_ingress)
            allow(load_balancers).to receive(:create).and_return(elb_1)
          end

          it 'creates and attaches a security group for the ELBs' do
            elb_1_security_group_args = {
              group_name: 'fake-stack-name_elb-1-name',
              description: 'ELB Security Group',
              vpc_id: 'fake-vpc-id',
            }
            expect(ec2_client).to receive(:create_security_group).with(elb_1_security_group_args).and_return(create_security_group_response_1)
            expect(elb_1_security_group).to receive(:authorize_ingress).with(:tcp, 1111, '0.0.0.0/0')

            elb_2_security_group_args = {
              group_name: 'fake-stack-name_elb-2-name',
              description: 'ELB Security Group',
              vpc_id: 'fake-vpc-id',
            }
            expect(ec2_client).to receive(:create_security_group).with(elb_2_security_group_args).and_return(create_security_group_response_2)
            expect(elb_2_security_group).to receive(:authorize_ingress).with(:tcp, 2222, '0.0.0.0/0')

            ami_manager.prepare_environment(cloudformation_template_file.path)
          end

          it 'attaches an elb with the name of the stack for the ELBs' do
            health_check_params = {
              healthy_threshold: 2,
              unhealthy_threshold: 5,
              interval: 5,
              timeout: 2,
            }
            elb_1_params = {
              listeners: [{protocol: 'TCP', load_balancer_port: 1111, instance_protocol: 'TCP', instance_port: 11}],
              subnets: ['fake-subnet-id'],
              security_groups: ['elb-1-security-group-id']
            }
            expect(load_balancers).to receive(:create).with('elb-1-name', elb_1_params).and_return(elb_1)
            expect(elb_1).to receive(:configure_health_check).with(
              health_check_params.merge(target: 'TCP:1234')
            )
            elb_2_params = {
              listeners: [{protocol: 'TCP', load_balancer_port: 2222, instance_protocol: 'TCP', instance_port: 22}],
              subnets: ['fake-subnet-id'],
              security_groups: ['elb-2-security-group-id']
            }
            expect(load_balancers).to receive(:create).with('elb-2-name', elb_2_params).and_return(elb_2)
            expect(elb_2).not_to receive(:configure_health_check)
            ami_manager.prepare_environment(cloudformation_template_file.path)
          end
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
        allow(elastic_ip).to receive(:exists?).and_return(true)
      end

      context 'when no IAM Profile is present' do
        it 'creates an instance' do
          expect(ec2).to receive_message_chain(:instances, :create).with(
            image_id: ami_id,
            key_name: 'ssh-key-name',
            security_group_ids: ['security-group-id'],
            subnet: 'public-subnet-id',
            instance_type: 'm3.medium').and_return(instance)

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end
      end

      context 'when IAM Profile is present' do
        let(:extra_outputs) { {'instance_profile' => 'FAKE_INSTANCE_PROFILE'} }

        it 'creates an instance passing the IAM Instance Profile' do
          expect(ec2).to receive_message_chain(:instances, :create).with(
            image_id: ami_id,
            key_name: 'ssh-key-name',
            security_group_ids: ['security-group-id'],
            subnet: 'public-subnet-id',
            iam_instance_profile: 'FAKE_INSTANCE_PROFILE',
            instance_type: 'm3.medium').and_return(instance)

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end
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
        before do
          allow(ec2).to receive_message_chain(:elastic_ips, :create).and_return(elastic_ip)
        end

        it 'waits for the Elastic IP to be created' do
          expect(elastic_ip).to receive(:exists?).exactly(AwsManager::RETRY_LIMIT - 1).times.and_return(false)
          expect(elastic_ip).to receive(:exists?).exactly(1).times.and_return(true)

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end

        it 'fails if the Elastic IP is not created in time' do
          expect(elastic_ip).to receive(:exists?).exactly(AwsManager::RETRY_LIMIT).times.and_return(false)

          expect { ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config) }.to raise_error(AwsManager::RetryLimitExceeded)
        end

        it 'creates and attaches an elastic IP' do
          expect(ec2).to receive_message_chain(:elastic_ips, :create).with(vpc: true).and_return(elastic_ip)

          expect(instance).to receive(:associate_elastic_ip).with(elastic_ip)

          ami_manager.deploy(ami_file_path: ami_file_path, vm_config: vm_config)
        end
      end

      context 'vm configuration contains an elastic IP' do
        let(:vm_config) do
          {
            'vm_name' => 'some-vm-name',
            'vm_ip_address' => 'some-ip-address',
            'key_name' => 'ssh-key-name',
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
      let(:instance1) { instance_double(AWS::EC2::Instance, tags: {}, id: 'instance1', status: :terminated) }
      let(:instance2) { instance_double(AWS::EC2::Instance, tags: {}, id: 'instance2', status: :terminated) }
      let(:subnet1_instances) { [instance1] }
      let(:subnet2_instances) { [instance2] }
      let(:cfn) { instance_double(AWS::CloudFormation, stacks: stack_collection) }
      let(:stack) { instance_double(AWS::CloudFormation::Stack, status: 'DELETE_COMPLETE', delete: nil) }
      let(:stack_collection) { instance_double(AWS::CloudFormation::StackCollection) }

      let(:instance1_volume) { instance_double(AWS::EC2::Volume, id: 'volume-id') }
      let(:instance1_attachment) do
        instance_double(AWS::EC2::Attachment, volume: instance1_volume, delete_on_termination: true)
      end

      let(:buckets) { instance_double(AWS::S3::BucketCollection) }
      let(:s3_client) { instance_double(AWS::S3, buckets: buckets) }

      before do
        allow(AWS::CloudFormation).to receive(:new).and_return(cfn)
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

        allow(ec2).to receive_message_chain(:instances, :[]).and_return(instance1, instance2)
      end

      it 'terminates all VMs in the subnet' do
        expect(instance1).to receive(:terminate)
        expect(instance2).to receive(:terminate)

        ami_manager.clean_environment
      end

      it 'ensures the instances are terminated' do
        expect(instance1).to receive(:status).and_return(:shutting_down, :shutting_down, :terminated)
        expect(instance2).to receive(:status).and_return(:terminated)

        ami_manager.clean_environment
      end

      it 'raises if any vms do not terminate' do
        allow(ec2).to receive_message_chain(:instances, :[]).and_return(instance1, instance2)

        expect(instance1).to receive(:status).and_return(:terminated).twice
        expect(instance2).to receive(:status).and_return(:running).exactly(3).times

        expect { ami_manager.clean_environment }.to raise_error("Expected instance: #{instance2.id} to be terminated, but was running")
      end

      it 'polls the status every 30' do
        expect(ami_manager).to receive(:retry_until).with(retry_limit: 90, retry_interval: 30)

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

      it 'stops retrying after 90 times' do
        expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS').
          exactly(90).times

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

      context 'when the stack fails to delete' do
        it 'retries deletes twice' do
          expect(stack).to receive(:delete).ordered
          expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS', 'DELETE_FAILED').ordered
          expect(stack).to receive(:delete).ordered
          expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS', 'DELETE_COMPLETE').ordered

          ami_manager.clean_environment
        end

        it 'fails after two delete retries' do
          expect(stack).to receive(:delete).ordered
          expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS', 'DELETE_FAILED').ordered
          expect(stack).to receive(:delete).ordered
          expect(stack).to receive(:status).and_return('DELETE_IN_PROGRESS', 'DELETE_FAILED').ordered

          expect {
            ami_manager.clean_environment
          }.to raise_error(/Two delete retries have failed/)
        end
      end

      context 'when a subnet is not provided' do
        before do
          env_config['outputs']['subnets'] = env_config['outputs']['subnets'][0..-2]
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
            'elbs' => [
              {
                'name' => 'elb-1-name',
                'port_mappings' => [[1111, 11]],
                'stack_output_keys' => {
                  'vpc_id' => 'vpc_id',
                  'subnet_id' => 'private_subnet',
                },
              },
              {
                'name' => 'elb-2-name',
                'port_mappings' => [[2222, 22]],
                'stack_output_keys' => {
                  'vpc_id' => 'vpc_id',
                  'subnet_id' => 'private_subnet',
                },
              }
            ],
          }
        end

        let(:elb) { instance_double(AWS::ELB, load_balancers: [load_balancer_1_to_delete, load_balancer_2_to_delete, other_load_balancer]) }
        let(:load_balancer_1_to_delete) do
          instance_double(AWS::ELB::LoadBalancer,
            name: 'elb-1-name',
            security_groups: [elb_1_security_group],
            exists?: false,
          )
        end
        let(:load_balancer_2_to_delete) do
          instance_double(AWS::ELB::LoadBalancer,
            name: 'elb-2-name',
            security_groups: [elb_2_security_group],
            exists?: false,
          )
        end
        let(:other_load_balancer) { instance_double(AWS::ELB::LoadBalancer, name: 'other-elb-name') }
        let(:elb_1_security_group) { instance_double(AWS::EC2::SecurityGroup, name: 'elb-1-security-group', id: 'sg-elb-1-id') }
        let(:elb_2_security_group) { instance_double(AWS::EC2::SecurityGroup, name: 'elb-2-security-group', id: 'sg-elb-2-id') }
        let(:network_interface_1_elb_1) do
          instance_double(AWS::EC2::NetworkInterface,
            security_groups: [elb_1_security_group],
            exists?: false,
          )
        end
        let(:network_interface_2_elb_1) do
          instance_double(AWS::EC2::NetworkInterface,
            security_groups: [elb_1_security_group],
            exists?: false,
          )
        end
        let(:network_interface_1_elb_2) do
          instance_double(AWS::EC2::NetworkInterface,
            security_groups: [elb_2_security_group],
            exists?: false,
          )
        end
        let(:network_interface_2_elb_2) do
          instance_double(AWS::EC2::NetworkInterface,
            security_groups: [elb_2_security_group],
            exists?: false,
          )
        end

        before do
          allow(AWS::ELB).to receive(:new).and_return(elb)
          allow(ec2).to receive(:network_interfaces).and_return(
            [
              network_interface_1_elb_1,
              network_interface_2_elb_1,
              network_interface_1_elb_2,
              network_interface_2_elb_2,
            ]
          )
          allow(load_balancer_1_to_delete).to receive(:delete)
          allow(load_balancer_2_to_delete).to receive(:delete)
          allow(elb_1_security_group).to receive(:delete)
          allow(elb_2_security_group).to receive(:delete)
        end

        it 'waits for the ELBs to be deleted' do
          expect(load_balancer_1_to_delete).to receive(:exists?).and_return(true).
            exactly(30).times
          expect(load_balancer_2_to_delete).not_to receive(:exists?)

          expect(elb_1_security_group).not_to receive(:delete).ordered
          expect(elb_2_security_group).not_to receive(:delete).ordered
          expect { ami_manager.clean_environment }.to raise_error(AwsManager::RetryLimitExceeded)
        end

        it 'waits for the network interfaces to be deleted' do
          allow(load_balancer_1_to_delete).to receive(:exists?).and_return(false)
          allow(load_balancer_2_to_delete).to receive(:exists?).and_return(false)

          expect(network_interface_1_elb_1).to receive(:exists?).and_return(false).
            exactly(30).times
          expect(network_interface_2_elb_1).to receive(:exists?).and_return(true).
            exactly(30).times
          expect(network_interface_1_elb_2).not_to receive(:exists?)
          expect(network_interface_2_elb_2).not_to receive(:exists?)

          expect(elb_1_security_group).not_to receive(:delete).ordered
          expect(elb_2_security_group).not_to receive(:delete).ordered
          expect { ami_manager.clean_environment }.to raise_error(AwsManager::RetryLimitExceeded)
        end

        it 'does not care about network interfaces deleted by other processes' do
          allow(network_interface_1_elb_1).to receive(:security_groups).and_raise(AWS::EC2::Errors::InvalidNetworkInterfaceID::NotFound)

          expect(load_balancer_1_to_delete).to receive(:delete).ordered
          expect(elb_1_security_group).to receive(:delete).ordered

          expect(load_balancer_2_to_delete).to receive(:delete).ordered
          expect(elb_2_security_group).to receive(:delete).ordered

          ami_manager.clean_environment
        end

        it 'terminates the ELBs then removes the security group' do
          expect(load_balancer_1_to_delete).to receive(:delete).ordered
          expect(elb_1_security_group).to receive(:delete).ordered

          expect(load_balancer_2_to_delete).to receive(:delete).ordered
          expect(elb_2_security_group).to receive(:delete).ordered

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
        let(:bucket_1) { instance_double(AWS::S3::Bucket) }
        let(:bucket_2) { instance_double(AWS::S3::Bucket) }
        let(:extra_outputs) { {'s3_bucket_names' => [bucket_name_1, bucket_name_2]} }
        let(:bucket_name_1) { 'bucket-name-1' }
        let(:bucket_name_2) { 'bucket-name-2' }

        before do
          allow(buckets).to receive(:[]).with(bucket_name_1).and_return(bucket_1)
          allow(buckets).to receive(:[]).with(bucket_name_2).and_return(bucket_2)
        end

        context 'and both buckets exist' do
          before do
            allow(bucket_1).to receive(:exists?).and_return(true)
            allow(bucket_2).to receive(:exists?).and_return(true)
          end

          it 'clears the bucket' do
            expect(bucket_1).to receive(:clear!)
            expect(bucket_2).to receive(:clear!)
            ami_manager.clean_environment
          end
        end

        context 'and only one bucket exists' do
          before do
            allow(bucket_1).to receive(:exists?).and_return(false)
            allow(bucket_2).to receive(:exists?).and_return(true)
          end

          it 'clears the bucket' do
            expect(bucket_1).not_to receive(:clear!)
            expect(bucket_2).to receive(:clear!)
            ami_manager.clean_environment
          end
        end

        context 'and neither bucket exists' do
          before do
            allow(bucket_1).to receive(:exists?).and_return(false)
            allow(bucket_2).to receive(:exists?).and_return(false)
          end

          it 'clears the bucket' do
            expect(bucket_1).not_to receive(:clear!)
            expect(bucket_2).not_to receive(:clear!)
            ami_manager.clean_environment
          end
        end

        context 'and the bucket name is empty' do
          let(:bucket_name_3) { '' }
          let(:extra_outputs) { {'s3_bucket_names' => [bucket_name_3, bucket_name_1, bucket_name_2]} }

          before do
            allow(bucket_1).to receive(:exists?).and_return(true)
            allow(bucket_2).to receive(:exists?).and_return(true)
          end

          it 'does not check if the bucket exists' do
            expect(buckets).not_to receive(:[]).with(bucket_name_3)
            expect(bucket_1).to receive(:clear!)
            expect(bucket_2).to receive(:clear!)
            ami_manager.clean_environment
          end
        end

        context 'and the bucket name is null' do
          let(:bucket_name_3) { nil }
          let(:extra_outputs) { {'s3_bucket_names' => [bucket_name_3, bucket_name_1, bucket_name_2]} }

          before do
            allow(bucket_1).to receive(:exists?).and_return(true)
            allow(bucket_2).to receive(:exists?).and_return(true)
          end

          it 'does not check if the bucket exists' do
            expect(buckets).not_to receive(:[]).with(bucket_name_3)
            expect(bucket_1).to receive(:clear!)
            expect(bucket_2).to receive(:clear!)
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
        allow(ec2).to receive_message_chain(:instances, :with_tag).and_return(instances)
        allow(instance).to receive(:terminate)
      end

      it 'terminates the VM with the specified name' do
        expect(non_terminated_instance).not_to receive(:terminate)
        expect(instance).to receive(:terminate)

        ami_manager.destroy(vm_config)
      end

      context 'when there is an elastic ip and it is not specified in env config' do
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

      context 'when there is an elastic ip and it is specified in env config' do
        let(:elastic_ip) { instance_double(AWS::EC2::ElasticIp) }
        let(:vm_config) do
          {
            'vm_name' => 'some-vm-name',
            'vm_ip_address' => 'some-ip-address'
          }
        end

        it 'terminates the VM with the specified name' do
          expect(non_terminated_instance).not_to receive(:terminate)
          expect(instance).to receive(:terminate)

          ami_manager.destroy(vm_config)
        end

        it 'does not destroy the elastic ip' do
          expect(elastic_ip).not_to receive(:delete).ordered

          ami_manager.destroy(vm_config)
        end
      end
    end
  end
end
