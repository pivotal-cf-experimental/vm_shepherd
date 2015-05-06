module VmShepherd
  class Shepherd
    class InvalidIaas < StandardError; end

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
            ami_manager(vm_shepherd_config).deploy(path)
          when VmShepherd::OPENSTACK_IAAS_TYPE then
            openstack_vm_manager(vm_shepherd_config).deploy(path, openstack_vm_options(vm_shepherd_config))
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
            ).destroy(vm_shepherd_config.vm.ip, vm_shepherd_config.vsphere.resource_pool)
          when VmShepherd::AWS_IAAS_TYPE then
            ami_manager(vm_shepherd_config).destroy
          when VmShepherd::OPENSTACK_IAAS_TYPE then
            openstack_vm_manager(vm_shepherd_config).destroy(openstack_vm_options(vm_shepherd_config))
        end
      end
    end

    def clean_environment
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
              error_logger,
            ).clean_environment(vm_shepherd_config.vapp.product_names, vm_shepherd_config.vapp.product_catalog)
          when VmShepherd::VSPHERE_IAAS_TYPE then
            VmShepherd::VsphereManager.new(
              vm_shepherd_config.vcenter_creds.ip,
              vm_shepherd_config.vcenter_creds.username,
              vm_shepherd_config.vcenter_creds.password,
              vm_shepherd_config.cleanup.datacenter,
            ).clean_environment(
              datacenter_folders_to_clean: vm_shepherd_config.cleanup.datacenter_folders_to_clean,
              datastores: vm_shepherd_config.cleanup.datastores,
              datastore_folders_to_clean: vm_shepherd_config.cleanup.datastore_folders_to_clean,
            )
          when VmShepherd::AWS_IAAS_TYPE then
            ami_manager(vm_shepherd_config).clean_environment
          when VmShepherd::OPENSTACK_IAAS_TYPE then
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

    def ami_manager(vm_shepherd_config)
      VmShepherd::AwsManager.new(
        aws_access_key: vm_shepherd_config.aws_access_key,
        aws_secret_key: vm_shepherd_config.aws_secret_key,
        ssh_key_name: vm_shepherd_config.ssh_key_name,
        security_group_id: vm_shepherd_config.security_group,
        public_subnet_id: vm_shepherd_config.public_subnet_id,
        private_subnet_id: vm_shepherd_config.private_subnet_id,
        elastic_ip_id: vm_shepherd_config.elastic_ip_id,
        vm_name: vm_shepherd_config.vm_name,
      )
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
        min_disk_size: vm_shepherd_config.vm.flavor_parameters.min_disk_size,
        network_name: vm_shepherd_config.vm.network_name,
        key_name: vm_shepherd_config.vm.key_name,
        security_group_names: vm_shepherd_config.vm.security_group_names,
        public_ip: vm_shepherd_config.vm.public_ip,
        private_ip: vm_shepherd_config.vm.private_ip,
      }
    end

    def vm_shepherd_configs(settings)
      settings.vm_shepherd_configs || []
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
