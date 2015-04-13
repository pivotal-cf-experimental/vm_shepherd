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

    def initialize(aws_options)
      AWS.config(
        access_key_id: aws_options.fetch(:aws_access_key),
        secret_access_key: aws_options.fetch(:aws_secret_key),
        region: AWS_REGION
      )
      @aws_options = aws_options
    end

    def deploy(ami_file_path)
      image_id = File.read(ami_file_path).strip

      instance =
        retry_ignoring_error_until(AWS::EC2::Errors::InvalidIPAddress::InUse) do
          AWS.ec2.instances.create(
            image_id: image_id,
            key_name: aws_options.fetch(:ssh_key_name),
            security_group_ids: [aws_options.fetch(:security_group_id)],
            subnet: aws_options.fetch(:public_subnet_id),
            instance_type: OPS_MANAGER_INSTANCE_TYPE
          )
        end

      retry_ignoring_error_until(AWS::EC2::Errors::InvalidInstanceID::NotFound) do
        instance.status == :running
      end

      instance.associate_elastic_ip(aws_options.fetch(:elastic_ip_id))
      instance.add_tag('Name', value: aws_options.fetch(:vm_name))
    end

    def destroy
      subnets = [
        AWS.ec2.subnets[aws_options.fetch(:public_subnet_id)],
        AWS.ec2.subnets[aws_options.fetch(:private_subnet_id)]
      ]

      volumes = []
      subnets.each do |subnet|
        subnet.instances.each do |instance|
          unless instance.tags.to_h.fetch(DO_NOT_TERMINATE_TAG_KEY, false)
            instance.attachments.each do |_, attachment|
              volumes.push(attachment.volume) unless attachment.delete_on_termination
            end
            instance.terminate
          end
        end
      end
      destroy_volumes(volumes)
    end

    def clean_environment
    end

    private
    attr_reader :aws_options

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

    def retry_ignoring_error_until(exception_class, &block)
      tries = 0
      condition_reached = false
      loop do
        begin
          tries += 1
          raise(RetryLimitExceeded) if tries > RETRY_LIMIT
          condition_reached = block.call
          sleep RETRY_INTERVAL
        rescue exception_class
          retry
        end
        break if condition_reached
      end
      condition_reached
    end
  end
end
