require 'aws-sdk-v1'

module VmShepherd
  class AwsManager
    class RetryLimitExceeded < StandardError
    end

    AWS_REGION = 'us-east-1'
    OPS_MANAGER_INSTANCE_TYPE = 'm3.medium'
    RETRY_LIMIT = 60
    RETRY_INTERVAL = 5
    DO_NOT_TERMINATE_TAG_KEY = 'do_not_terminate'

    def initialize(env_config)
      AWS.config(
        access_key_id: env_config.fetch(:aws_access_key),
        secret_access_key: env_config.fetch(:aws_secret_key),
        region: AWS_REGION
      )
      @env_config = env_config
    end

    def prepare_environment(cloudformation_template_file)
      template = File.read(cloudformation_template_file)

      cfm = AWS::CloudFormation.new
      stack = cfm.stacks.create(env_config.fetch(:stack_name), template, :parameters => env_config.fetch(:parameters), capabilities: ['CAPABILITY_IAM'])

      retry_until(retry_limit: 360) do
        status = stack.status
        case status
          when 'CREATE_COMPLETE'
            true
          when 'CREATE_IN_PROGRESS'
            false
          when 'ROLLBACK_IN_PROGRESS'
            false
          else
            stack.delete if status == 'ROLLBACK_COMPLETE'
            raise "Unexpected status for stack #{env_config.fetch(:stack_name)} : #{status}"
        end
      end
    end

    def deploy(ami_file_path:, vm_config:)
      image_id = File.read(ami_file_path).strip

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

      retry_until do
        begin
          instance.status == :running
        rescue AWS::EC2::Errors::InvalidInstanceID::NotFound
          false
        end
      end

      elastic_ip = AWS.ec2.elastic_ips.create(vpc: true)
      instance.associate_elastic_ip(elastic_ip.allocation_id)
      instance.add_tag('Name', value: vm_config.fetch(:vm_name))
    end

    def clean_environment
      subnets = []
      subnets << AWS.ec2.subnets[env_config.fetch(:outputs).fetch(:public_subnet_id)] if env_config.fetch(:outputs).fetch(:public_subnet_id)
      subnets << AWS.ec2.subnets[env_config.fetch(:outputs).fetch(:private_subnet_id)] if env_config.fetch(:outputs).fetch(:private_subnet_id)

      volumes = []
      subnets.each do |subnet|
        subnet.instances.each do |instance|
          instance.attachments.each do |_, attachment|
            volumes.push(attachment.volume) unless attachment.delete_on_termination
          end
          instance.terminate
        end
      end
      destroy_volumes(volumes)

      cfm = AWS::CloudFormation.new
      stack = cfm.stacks[env_config.fetch(:stack_name)]
      stack.delete
      retry_until(retry_limit: 360) do
        begin
          status = stack.status
          case status
            when 'DELETE_COMPLETE'
              true
            when 'DELETE_IN_PROGRESS'
              false
            else
              raise "Unexpected status for stack #{env_config.fetch(:stack_name)} : #{status}"
          end
        rescue AWS::CloudFormation::Errors::ValidationError
          raise if stack.exists?
          true
        end
      end if stack
    end

    def destroy(vm_config)
      AWS.ec2.instances.each do |instance|
        if instance.tags.to_h['Name'] == vm_config.fetch(:vm_name)
          instance.elastic_ip.delete
          instance.terminate
        end
      end
    end

    private
    attr_reader :env_config

    def destroy_volumes(volumes)
      volumes.each do |volume|
        begin
          volume.delete
        rescue AWS::EC2::Errors::VolumeInUse
          sleep 5
          retry
        end
      end
    end

    def retry_until(retry_limit: RETRY_LIMIT, &block)
      tries = 0
      condition_reached = false
      loop do
        tries += 1
        raise(RetryLimitExceeded) if tries > retry_limit
        condition_reached = block.call
        break if condition_reached
        sleep RETRY_INTERVAL
      end
      condition_reached
    end
  end
end
