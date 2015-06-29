require 'aws-sdk-v1'
require 'vm_shepherd/retry_helper'

module VmShepherd
  class AwsManager
    include VmShepherd::RetryHelper

    OPS_MANAGER_INSTANCE_TYPE = 'm3.medium'
    DO_NOT_TERMINATE_TAG_KEY = 'do_not_terminate'
    ELB_SECURITY_GROUP_NAME = 'ELB Security Group'

    CREATE_IN_PROGRESS = 'CREATE_IN_PROGRESS'
    CREATE_COMPLETE = 'CREATE_COMPLETE'
    ROLLBACK_IN_PROGRESS = 'ROLLBACK_IN_PROGRESS'
    ROLLBACK_COMPLETE = 'ROLLBACK_COMPLETE'
    DELETE_IN_PROGRESS = 'DELETE_IN_PROGRESS'
    DELETE_COMPLETE = 'DELETE_COMPLETE'

    def initialize(env_config:, logger:)
      AWS.config(
        access_key_id: env_config.fetch(:aws_access_key),
        secret_access_key: env_config.fetch(:aws_secret_key),
        region: env_config.fetch(:region),
      )
      @env_config = env_config
      @logger = logger
    end

    def prepare_environment(cloudformation_template_file)
      template = File.read(cloudformation_template_file)

      cfm = AWS::CloudFormation.new
      logger.info('Starting CloudFormation Stack Creation')
      stack = cfm.stacks.create(env_config.fetch(:stack_name), template, parameters: env_config.fetch(:parameters), capabilities: ['CAPABILITY_IAM'])

      logger.info("Waiting for status: #{CREATE_COMPLETE}")
      retry_until(retry_limit: 30) do
        status = stack.status
        logger.info("current stack status: #{status}")
        case status
          when CREATE_COMPLETE
            true
          when CREATE_IN_PROGRESS
            false
          when ROLLBACK_IN_PROGRESS
            false
          else
            stack.delete if status == ROLLBACK_COMPLETE
            raise "Unexpected status for stack #{env_config.fetch(:stack_name)} : #{status}"
        end
      end

      env_config.fetch(:elbs, []).each do |elb_config|
        create_elb(stack, elb_config)
      end
    end

    def deploy(ami_file_path:, vm_config:)
      image_id = read_ami_id(ami_file_path)

      logger.info('Starting AMI Instance creation')
      instance =
        retry_until do
          begin
            AWS.ec2.instances.create(
              image_id: image_id,
              key_name: env_config.fetch(:outputs).fetch(:ssh_key_name),
              security_group_ids: [env_config.fetch(:outputs).fetch(:security_group)],
              subnet: env_config.fetch(:outputs).fetch(:public_subnet_id),
              instance_type: OPS_MANAGER_INSTANCE_TYPE
            )
          rescue AWS::EC2::Errors::InvalidIPAddress::InUse
            false
          end
        end

      logger.info('waiting until the instance status is running')
      retry_until do
        begin
          status = instance.status
          logger.info("current status: #{status}")
          status == :running
        rescue AWS::EC2::Errors::InvalidInstanceID::NotFound
          false
        end
      end

      vm_ip_address = vm_config.fetch(:vm_ip_address, nil)
      if vm_ip_address
        logger.info('Associating existing IP to the instance')
        elastic_ip = AWS::EC2::ElasticIp.new(vm_ip_address)
      else
        logger.info('Creating an Elastic IP and assigning it to the instance')
        elastic_ip = AWS.ec2.elastic_ips.create(vpc: true)
      end
      instance.associate_elastic_ip(elastic_ip)
      instance.add_tag('Name', value: vm_config.fetch(:vm_name))
    end

    def clean_environment
      [:public_subnet_id, :private_subnet_id].each do |subnet_id|
        aws_subnet_id = env_config.fetch(:outputs).fetch(subnet_id)
        clear_subnet(aws_subnet_id) if aws_subnet_id
      end

      env_config.fetch(:elbs, []).each do |elb_config|
        delete_elb(elb_config[:name])
      end

      bucket_names = env_config.fetch(:outputs, {}).fetch(:s3_bucket_names, []).compact
      bucket_names.each do |bucket_name|
        next if bucket_name.empty?
        bucket = AWS::S3.new.buckets[bucket_name]
        if bucket && bucket.exists?
          logger.info("clearing bucket: #{bucket_name}")
          bucket.clear!
        end
      end

      delete_stack(env_config.fetch(:stack_name))
    end

    def destroy(vm_config)
      AWS.ec2.instances.each do |instance|
        if instance.tags.to_h['Name'] == vm_config.fetch(:vm_name)
          elastic_ip = instance.elastic_ip
          if elastic_ip
            elastic_ip.disassociate
            elastic_ip.delete
          end
          instance.terminate
        end
      end
    end

    private
    attr_reader :env_config, :logger

    def subnet_id(stack, elb_config)
      stack.outputs.detect { |o| o.key == elb_config[:stack_output_keys][:subnet_id] }.value
    end

    def vpc_id(stack, elb_config)
      stack.outputs.detect { |o| o.key == elb_config[:stack_output_keys][:vpc_id] }.value
    end

    def clear_subnet(subnet_id)
      logger.info("Clearing contents of subnet: #{subnet_id}")
      subnet = AWS.ec2.subnets[subnet_id]
      volumes = []
      subnet.instances.each do |instance|
        instance.attachments.each do |_, attachment|
          volumes.push(attachment.volume) unless attachment.delete_on_termination
        end
        logger.info("terminating instance #{instance.id}")
        instance.terminate
      end
      destroy_volumes(volumes)
    end

    def destroy_volumes(volumes)
      volumes.each do |volume|
        begin
          logger.info("trying to delete volume: #{volume.id}")
          volume.delete
        rescue AWS::EC2::Errors::VolumeInUse
          sleep VmShepherd::RetryHelper::RETRY_INTERVAL
          retry
        end
      end
    end

    def delete_elb(elb_name)
      if (elb = AWS::ELB.new.load_balancers.find { |lb| lb.name == elb_name })
        sg = elb.security_groups.first
        net_interfaces = AWS.ec2.network_interfaces.select { |ni| ni.security_groups.map(&:id).include? sg.id }
        logger.info("deleting elb: #{elb.name}")
        elb.delete
        logger.info('waiting until elb is deleted')
        retry_until(retry_limit: 30) do
          !elb.exists? && !net_interfaces.map(&:exists?).any?
        end
        logger.info("deleting elb security group: #{sg.id}")
        sg.delete
      end
    end

    def create_elb(stack, elb_config)
      elb = AWS::ELB.new
      elb_params = {
        load_balancer_name: elb_config[:name],
        listeners: [],
        subnets: [subnet_id(stack, elb_config)],
        security_groups: [create_security_group(stack, elb_config).security_group_id]
      }

      elb_config[:port_mappings].each do |port_mapping|
        elb_params[:listeners] << {
          protocol: 'TCP', load_balancer_port: port_mapping[0],
          instance_protocol: 'TCP', instance_port: port_mapping[1]
        }
      end

      logger.info('Creating an ELB')
      elb.client.create_load_balancer(elb_params)
    end

    def create_security_group(stack, elb_config)
      vpc_id = vpc_id(stack, elb_config)
      sg_params = {
        group_name: [stack.name, elb_config[:name]].join('_'),
        description: 'ELB Security Group',
        vpc_id: vpc_id,
      }

      logger.info('Creating a Security Group for the ELB')
      security_group_response = AWS.ec2.client.create_security_group(sg_params)

      AWS.ec2.security_groups[security_group_response[:group_id]].tap do |security_group|
        elb_config[:port_mappings].each do |port_mapping|
          security_group.authorize_ingress(:tcp, port_mapping[0], '0.0.0.0/0')
        end
      end
    end

    def delete_stack(stack_name)
      cfm = AWS::CloudFormation.new
      stack = cfm.stacks[stack_name]
      logger.info('deleting CloudFormation stack')
      stack.delete
      logger.info("waiting until status: #{DELETE_COMPLETE}")
      retry_until(retry_limit: 30) do
        begin
          status = stack.status
          logger.info("current stack status: #{status}")
          case status
            when DELETE_COMPLETE
              true
            when DELETE_IN_PROGRESS
              false
            else
              raise "Unexpected status for stack #{stack_name} : #{status}"
          end
        rescue AWS::CloudFormation::Errors::ValidationError
          raise if stack.exists?
          logger.info('stack deleted successfully')
          true
        end
      end if stack
    end

    def read_ami_id(ami_file_path)
      YAML.load_file(ami_file_path)[env_config.fetch(:region)]
    end
  end
end
