require 'aws-sdk-v1'
require 'vm_shepherd/retry_helper'

module VmShepherd
  class AwsManager
    include VmShepherd::RetryHelper

    AWS_REGION = 'us-east-1'
    OPS_MANAGER_INSTANCE_TYPE = 'm3.medium'
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
      stack = cfm.stacks.create(env_config.fetch(:stack_name), template, parameters: env_config.fetch(:parameters), capabilities: ['CAPABILITY_IAM'])

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

      if (elb_config = env_config[:elb])
        create_elb(elb_config, subnet_id(stack, elb_config))
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

      if (elb_config = env_config[:elb])
        delete_elb(elb_config[:name])
      end

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
    attr_reader :env_config

    def subnet_id(stack, elb_config)
      stack.outputs.detect { |o| o.key == elb_config[:stack_output_keys][:subnet_id] }.value
    end

    def delete_elb(elb_name)
      if (elb = AWS::ELB.new.load_balancers.find { |lb| lb.name == elb_name })
        elb.delete
      end
    end

    def create_elb(elb_config, subnet_id)
      elb = AWS::ELB.new
      elb_params = {
        load_balancer_name: elb_config[:name],
        listeners: [],
        subnets: [subnet_id],
      }

      elb_config[:port_mappings].each do |port_mapping|
        elb_params[:listeners] << {
          protocol: 'TCP', load_balancer_port: port_mapping[0],
          instance_protocol: 'TCP', instance_port: port_mapping[1]
        }
      end

      elb.client.create_load_balancer(elb_params)
    end

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
  end
end
