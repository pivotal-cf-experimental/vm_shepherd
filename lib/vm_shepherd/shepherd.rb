module VmShepherd
  class Shepherd
    class InvalidIaas < StandardError;
    end

    def initialize(settings:)
      @settings = settings
    end

    def deploy(paths:)
      unless valid_iaas_types.include?(settings.iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
      configs = vm_shepherd_configs(settings)
      unless configs.size == paths.size
        fail(ArgumentError, "mismatch in available images to deploy (needed #{configs.size}, got #{paths.size})")
      end
      configs.zip(paths).each do |vm_shepherd_config, path|
        case settings.iaas_type
          when VmShepherd::VCLOUD_IAAS_TYPE then
            VmShepherd::VcloudManager.new(
              {
                url: vm_shepherd_config.creds.url,
                organization: vm_shepherd_config.creds.organization,
                user: vm_shepherd_config.creds.user,
                password: vm_shepherd_config.creds.password,
              },
              vm_shepherd_config.vdc.name,
              error_logger
            ).deploy(
              path,
              vcloud_deploy_options(vm_shepherd_config),
            )
          when VmShepherd::VSPHERE_IAAS_TYPE then
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.vcenter_creds.ip,
              vm_shepherd_config.vcenter_creds.username,
              vm_shepherd_config.vcenter_creds.password,
              vm_shepherd_config.vsphere.datacenter,
              error_logger,
            ).deploy(
              path,
              {
                ip: vm_shepherd_config.vm.ip,
                gateway: vm_shepherd_config.vm.gateway,
                netmask: vm_shepherd_config.vm.netmask,
                dns: vm_shepherd_config.vm.dns,
                ntp_servers: vm_shepherd_config.vm.ntp_servers,
              },
              {
                cluster: vm_shepherd_config.vsphere.cluster,
                resource_pool: vm_shepherd_config.vsphere.resource_pool,
                datastore: vm_shepherd_config.vsphere.datastore,
                network: vm_shepherd_config.vsphere.network,
                folder: vm_shepherd_config.vsphere.folder,
              }
            )
          when VmShepherd::AWS_IAAS_TYPE then
            ami_manager.deploy(ami_file_path: path, vm_config: vm_shepherd_config.to_h)
          when VmShepherd::OPENSTACK_IAAS_TYPE then
            openstack_vm_manager(vm_shepherd_config).deploy(path, openstack_vm_options(vm_shepherd_config))
        end
      end
    end

    def prepare_environment
      unless valid_iaas_types.include?(settings.iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          vm_shepherd_configs(settings).each do |vm_shepherd_config|
            VmShepherd::VcloudManager.new(
              {
                url: vm_shepherd_config.creds.url,
                organization: vm_shepherd_config.creds.organization,
                user: vm_shepherd_config.creds.user,
                password: vm_shepherd_config.creds.password,
              },
              vm_shepherd_config.vdc.name,
              error_logger
            ).prepare_environment
          end
        when VmShepherd::VSPHERE_IAAS_TYPE then
          vm_shepherd_configs(settings).each do |vm_shepherd_config|
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.vcenter_creds.ip,
              vm_shepherd_config.vcenter_creds.username,
              vm_shepherd_config.vcenter_creds.password,
              vm_shepherd_config.vsphere.datacenter,
              error_logger,
            ).prepare_environment
          end
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.prepare_environment(settings.vm_shepherd.env_config.json_file)
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          vm_shepherd_configs(settings).each do |vm_shepherd_config|
            openstack_vm_manager(vm_shepherd_config).prepare_environment
          end
      end
    end

    def destroy
      unless valid_iaas_types.include?(settings.iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
      vm_shepherd_configs(settings).each do |vm_shepherd_config|
        case settings.iaas_type
          when VmShepherd::VCLOUD_IAAS_TYPE then
            VmShepherd::VcloudManager.new(
              {
                url: vm_shepherd_config.creds.url,
                organization: vm_shepherd_config.creds.organization,
                user: vm_shepherd_config.creds.user,
                password: vm_shepherd_config.creds.password,
              },
              vm_shepherd_config.vdc.name,
              error_logger
            ).destroy([vm_shepherd_config.vapp.ops_manager_name], vm_shepherd_config.vdc.catalog)
          when VmShepherd::VSPHERE_IAAS_TYPE then
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.vcenter_creds.ip,
              vm_shepherd_config.vcenter_creds.username,
              vm_shepherd_config.vcenter_creds.password,
              vm_shepherd_config.vsphere.datacenter,
              error_logger,
            ).destroy(vm_shepherd_config.vm.ip, vm_shepherd_config.vsphere.resource_pool)
          when VmShepherd::AWS_IAAS_TYPE then
            ami_manager.destroy(vm_shepherd_config.to_h)
          when VmShepherd::OPENSTACK_IAAS_TYPE then
            openstack_vm_manager(vm_shepherd_config).destroy(openstack_vm_options(vm_shepherd_config))
        end
      end
    end

    def clean_environment
      unless valid_iaas_types.include?(settings.iaas_type)
        fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          vm_shepherd_configs(settings).each do |vm_shepherd_config|
            VmShepherd::VcloudManager.new(
              {
                url: vm_shepherd_config.creds.url,
                organization: vm_shepherd_config.creds.organization,
                user: vm_shepherd_config.creds.user,
                password: vm_shepherd_config.creds.password,
              },
              vm_shepherd_config.vdc.name,
              error_logger,
            ).clean_environment(vm_shepherd_config.vapp.product_names || [], vm_shepherd_config.vapp.product_catalog)
          end
        when VmShepherd::VSPHERE_IAAS_TYPE then
          vm_shepherd_configs(settings).each do |vm_shepherd_config|
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.vcenter_creds.ip,
              vm_shepherd_config.vcenter_creds.username,
              vm_shepherd_config.vcenter_creds.password,
              vm_shepherd_config.cleanup.datacenter,
              error_logger,
            ).clean_environment(
              datacenter_folders_to_clean: vm_shepherd_config.cleanup.datacenter_folders_to_clean,
              datastores: vm_shepherd_config.cleanup.datastores,
              datastore_folders_to_clean: vm_shepherd_config.cleanup.datastore_folders_to_clean,
            )
          end
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.clean_environment
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          vm_shepherd_configs(settings).each do |vm_shepherd_config|
            openstack_vm_manager(vm_shepherd_config).clean_environment
          end
      end
    end

    private

    attr_reader :settings

    def error_logger
      Logger.new(STDOUT).tap do |lggr|
        lggr.level = Logger::Severity::ERROR
      end
    end

    def vcloud_deploy_options(vm_shepherd_config)
      vm = vm_shepherd_config.vapp
      {
        name: vm.ops_manager_name,
        ip: vm.ip,
        gateway: vm.gateway,
        netmask: vm.netmask,
        dns: vm.dns,
        ntp: vm.ntp,
        catalog: vm_shepherd_config.vdc.catalog,
        network: vm_shepherd_config.vdc.network,
      }
    end

    def ami_manager
      @ami_manager ||=
        VmShepherd::AwsManager.new(
          env_config: {
            stack_name: settings.vm_shepherd.env_config.stack_name,
            aws_access_key: settings.vm_shepherd.env_config.aws_access_key,
            aws_secret_key: settings.vm_shepherd.env_config.aws_secret_key,
            region: settings.vm_shepherd.env_config.region,
            json_file: settings.vm_shepherd.env_config.json_file,
            parameters: settings.vm_shepherd.env_config.parameters_as_a_hash,
            outputs: settings.vm_shepherd.env_config.outputs.to_h,
          }.merge(ami_elb_config),
          logger: error_logger,
        )
    end

    def ami_elb_config
      if settings.vm_shepherd.env_config.elb
        {
          elb: {
            name: settings.vm_shepherd.env_config.elb.name,
            port_mappings: settings.vm_shepherd.env_config.elb.port_mappings,
            stack_output_keys: settings.vm_shepherd.env_config.elb.stack_output_keys.to_h,
          }
        }
      else
        {}
      end
    end

    def openstack_vm_manager(vm_shepherd_config)
      OpenstackManager.new(
        auth_url: vm_shepherd_config.creds.auth_url,
        username: vm_shepherd_config.creds.username,
        api_key: vm_shepherd_config.creds.api_key,
        tenant: vm_shepherd_config.creds.tenant,
      )
    end

    def openstack_vm_options(vm_shepherd_config)
      {
        name: vm_shepherd_config.vm.name,
        flavor_name: vm_shepherd_config.vm.flavor_name,
        network_name: vm_shepherd_config.vm.network_name,
        key_name: vm_shepherd_config.vm.key_name,
        security_group_names: vm_shepherd_config.vm.security_group_names,
        public_ip: vm_shepherd_config.vm.public_ip,
        private_ip: vm_shepherd_config.vm.private_ip,
      }
    end

    def vm_shepherd_configs(settings)
      settings.vm_shepherd.vm_configs || []
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
