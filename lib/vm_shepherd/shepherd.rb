require 'vm_shepherd'
require 'vm_shepherd/backport_refinements'

using VmShepherd::BackportRefinements

module VmShepherd
  class Shepherd
    class InvalidIaas < StandardError;
    end

    def initialize(settings:)
      @iaas_type  = settings.dig('iaas_type')
      @configs    = settings.dig('vm_shepherd', 'vm_configs') || []
      @env_config = settings.dig('vm_shepherd', 'env_config')
    end

    def deploy(paths:)
      unless valid_iaas_types.include?(@iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{@iaas_type.inspect}")
      end
      unless @configs.size == paths.size
        fail(ArgumentError, "mismatch in available images to deploy (needed #{@configs.size}, got #{paths.size})")
      end
      @configs.zip(paths).each do |vm_shepherd_config, path|
        case @iaas_type
          when VmShepherd::VCLOUD_IAAS_TYPE then
            VmShepherd::VcloudManager.new(
              {
                url:          vm_shepherd_config.dig('creds', 'url'),
                organization: vm_shepherd_config.dig('creds', 'organization'),
                user:         vm_shepherd_config.dig('creds', 'user'),
                password:     vm_shepherd_config.dig('creds', 'password'),
              },
              vm_shepherd_config.dig('vdc', 'name'),
              stdout_logger
            ).deploy(
              path,
              vcloud_deploy_options(vm_shepherd_config),
            )
          when VmShepherd::VSPHERE_IAAS_TYPE then
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.dig('vcenter_creds', 'ip'),
              vm_shepherd_config.dig('vcenter_creds', 'username'),
              vm_shepherd_config.dig('vcenter_creds', 'password'),
              vm_shepherd_config.dig('vsphere', 'datacenter'),
              stdout_logger,
            ).deploy(
              path,
              {
                ip:          vm_shepherd_config.dig('vm', 'ip'),
                gateway:     vm_shepherd_config.dig('vm', 'gateway'),
                netmask:     vm_shepherd_config.dig('vm', 'netmask'),
                dns:         vm_shepherd_config.dig('vm', 'dns'),
                ntp_servers: vm_shepherd_config.dig('vm', 'ntp_servers'),
              },
              {
                cluster:       vm_shepherd_config.dig('vsphere', 'cluster'),
                resource_pool: vm_shepherd_config.dig('vsphere', 'resource_pool'),
                datastore:     vm_shepherd_config.dig('vsphere', 'datastore'),
                network:       vm_shepherd_config.dig('vsphere', 'network'),
                folder:        vm_shepherd_config.dig('vsphere', 'folder'),
              }
            )
          when VmShepherd::AWS_IAAS_TYPE then
            ami_manager.deploy(ami_file_path: path, vm_config: vm_shepherd_config)
          when VmShepherd::OPENSTACK_IAAS_TYPE then
            openstack_vm_manager(vm_shepherd_config).deploy(path, openstack_vm_options(vm_shepherd_config))
        end
      end
    end

    def prepare_environment
      unless valid_iaas_types.include?(@iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{@iaas_type.inspect}")
      end
      case @iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          @configs.each do |vm_shepherd_config|
            VmShepherd::VcloudManager.new(
              {
                url:          vm_shepherd_config.dig('creds', 'url'),
                organization: vm_shepherd_config.dig('creds', 'organization'),
                user:         vm_shepherd_config.dig('creds', 'user'),
                password:     vm_shepherd_config.dig('creds', 'password'),
              },
              vm_shepherd_config.dig('vdc', 'name'),
              stdout_logger
            ).prepare_environment
          end
        when VmShepherd::VSPHERE_IAAS_TYPE then
          @configs.each do |vm_shepherd_config|
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.dig('vcenter_creds', 'ip'),
              vm_shepherd_config.dig('vcenter_creds', 'username'),
              vm_shepherd_config.dig('vcenter_creds', 'password'),
              vm_shepherd_config.dig('vsphere', 'datacenter'),
              stdout_logger,
            ).prepare_environment
          end
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.prepare_environment(@env_config.dig('json_file'))
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          @configs.each do |vm_shepherd_config|
            openstack_vm_manager(vm_shepherd_config).prepare_environment
          end
      end
    end

    def destroy
      unless valid_iaas_types.include?(@iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{@iaas_type.inspect}")
      end
      @configs.each do |vm_shepherd_config|
        case @iaas_type
          when VmShepherd::VCLOUD_IAAS_TYPE then
            VmShepherd::VcloudManager.new(
              {
                url:          vm_shepherd_config.dig('creds', 'url'),
                organization: vm_shepherd_config.dig('creds', 'organization'),
                user:         vm_shepherd_config.dig('creds', 'user'),
                password:     vm_shepherd_config.dig('creds', 'password'),
              },
              vm_shepherd_config.dig('vdc', 'name'),
              stdout_logger
            ).destroy([vm_shepherd_config.dig('vapp', 'ops_manager_name')], vm_shepherd_config.dig('vdc', 'catalog'))
          when VmShepherd::VSPHERE_IAAS_TYPE then
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.dig('vcenter_creds', 'ip'),
              vm_shepherd_config.dig('vcenter_creds', 'username'),
              vm_shepherd_config.dig('vcenter_creds', 'password'),
              vm_shepherd_config.dig('vsphere', 'datacenter'),
              stdout_logger,
            ).destroy(vm_shepherd_config.dig('vm', 'ip'), vm_shepherd_config.dig('vsphere', 'resource_pool'))
          when VmShepherd::AWS_IAAS_TYPE then
            ami_manager.destroy(vm_shepherd_config)
          when VmShepherd::OPENSTACK_IAAS_TYPE then
            openstack_vm_manager(vm_shepherd_config).destroy(openstack_vm_options(vm_shepherd_config))
        end
      end
    end

    def clean_environment
      unless valid_iaas_types.include?(@iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{@iaas_type.inspect}")
      end
      case @iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          @configs.each do |vm_shepherd_config|
            VmShepherd::VcloudManager.new(
              {
                url:          vm_shepherd_config.dig('creds', 'url'),
                organization: vm_shepherd_config.dig('creds', 'organization'),
                user:         vm_shepherd_config.dig('creds', 'user'),
                password:     vm_shepherd_config.dig('creds', 'password'),
              },
              vm_shepherd_config.dig('vdc', 'name'),
              stdout_logger,
            ).clean_environment(vm_shepherd_config.dig('vapp', 'product_names')|| [], vm_shepherd_config.dig('vapp', 'product_catalog'))
          end
        when VmShepherd::VSPHERE_IAAS_TYPE then
          @configs.each do |vm_shepherd_config|
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.dig('vcenter_creds', 'ip'),
              vm_shepherd_config.dig('vcenter_creds', 'username'),
              vm_shepherd_config.dig('vcenter_creds', 'password'),
              vm_shepherd_config.dig('cleanup', 'datacenter'),
              stdout_logger,
            ).clean_environment(
              datacenter_folders_to_clean: vm_shepherd_config.dig('cleanup', 'datacenter_folders_to_clean'),
              datastores:                  vm_shepherd_config.dig('cleanup', 'datastores'),
              datastore_folders_to_clean:  vm_shepherd_config.dig('cleanup', 'datastore_folders_to_clean'),
            )
          end
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.clean_environment
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          @configs.each do |vm_shepherd_config|
            openstack_vm_manager(vm_shepherd_config).clean_environment
          end
      end
    end

    private


    def stdout_logger
      Logger.new(STDOUT)
    end

    def vcloud_deploy_options(vm_shepherd_config)
      VmShepherd::Vcloud::VappConfig.new(
        name:    vm_shepherd_config.dig('vapp', 'ops_manager_name'),
        ip:      vm_shepherd_config.dig('vapp', 'ip'),
        gateway: vm_shepherd_config.dig('vapp', 'gateway'),
        netmask: vm_shepherd_config.dig('vapp', 'netmask'),
        dns:     vm_shepherd_config.dig('vapp', 'dns'),
        ntp:     vm_shepherd_config.dig('vapp', 'ntp'),
        catalog: vm_shepherd_config.dig('vdc', 'catalog'),
        network: vm_shepherd_config.dig('vdc', 'network'),
      )
    end

    def ami_manager
      @ami_manager ||=
        VmShepherd::AwsManager.new(
          env_config: {
                        'stack_name'     => @env_config.dig('stack_name'),
                        'aws_access_key' => @env_config.dig('aws_access_key'),
                        'aws_secret_key' => @env_config.dig('aws_secret_key'),
                        'region'         => @env_config.dig('region'),
                        'json_file'      => @env_config.dig('json_file'),
                        'parameters'     => @env_config.dig('parameters'),
                        'outputs'        => @env_config.dig('outputs'),
                      }.merge(ami_elb_config),
          logger:     stdout_logger,
        )
    end

    def ami_elb_config
      if @env_config.dig('elbs')
        {
          'elbs' => @env_config.dig('elbs').map do |elb|
            {
              'name'              => elb.dig('name'),
              'port_mappings'     => elb.dig('port_mappings'),
              'stack_output_keys' => elb.dig('stack_output_keys'),
            }
          end
        }
      else
        {}
      end
    end

    def openstack_vm_manager(vm_shepherd_config)
      OpenstackManager.new(
        auth_url: vm_shepherd_config.dig('creds', 'auth_url'),
        username: vm_shepherd_config.dig('creds', 'username'),
        api_key:  vm_shepherd_config.dig('creds', 'api_key'),
        tenant:   vm_shepherd_config.dig('creds', 'tenant'),
      )
    end

    def openstack_vm_options(vm_shepherd_config)
      {
        name:                 vm_shepherd_config.dig('vm', 'name'),
        flavor_name:          vm_shepherd_config.dig('vm', 'flavor_name'),
        network_name:         vm_shepherd_config.dig('vm', 'network_name'),
        key_name:             vm_shepherd_config.dig('vm', 'key_name'),
        security_group_names: vm_shepherd_config.dig('vm', 'security_group_names'),
        public_ip:            vm_shepherd_config.dig('vm', 'public_ip'),
        private_ip:           vm_shepherd_config.dig('vm', 'private_ip'),
      }
    end

    def valid_iaas_types
      [
        VmShepherd::VCLOUD_IAAS_TYPE,
        VmShepherd::VSPHERE_IAAS_TYPE,
        VmShepherd::AWS_IAAS_TYPE,
        VmShepherd::OPENSTACK_IAAS_TYPE
      ]
    end
  end
end
