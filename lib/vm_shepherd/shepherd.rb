module VmShepherd
  class Shepherd
    class InvalidIaas < StandardError; end

    def initialize(settings:)
      @settings = settings
    end

    def deploy(path:)
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          VmShepherd::VcloudManager.new(
            {
              url: settings.vm_shepherd.creds.url,
              organization: settings.vm_shepherd.creds.organization,
              user: settings.vm_shepherd.creds.user,
              password: settings.vm_shepherd.creds.password,
            },
            {
              vdc: settings.vm_shepherd.vdc.name,
              catalog: settings.vm_shepherd.vdc.catalog,
              network: settings.vm_shepherd.vdc.network,
            },
            error_logger
          ).deploy(
            path,
            vcloud_deploy_options,
          )
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::VsphereManager.new(
            settings.vm_shepherd.vcenter_creds.ip,
            settings.vm_shepherd.vcenter_creds.username,
            settings.vm_shepherd.vcenter_creds.password,
            settings.vm_shepherd.vsphere.datacenter,
          ).deploy(
            path,
            {
              ip: settings.vm_shepherd.vm.ip,
              gateway: settings.vm_shepherd.vm.gateway,
              netmask: settings.vm_shepherd.vm.netmask,
              dns: settings.vm_shepherd.vm.dns,
              ntp_servers: settings.vm_shepherd.vm.ntp_servers,
            },
            {
              cluster: settings.vm_shepherd.vsphere.cluster,
              resource_pool: settings.vm_shepherd.vsphere.resource_pool,
              datastore: settings.vm_shepherd.vsphere.datastore,
              network: settings.vm_shepherd.vsphere.network,
              folder: settings.vm_shepherd.vsphere.folder,
            }
          )
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.deploy(path)
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          openstack_vm_manager.deploy(path, openstack_vm_options)
        else
          fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
    end

    def destroy
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          VmShepherd::VcloudManager.new(
            {
              url: settings.vm_shepherd.creds.url,
              organization: settings.vm_shepherd.creds.organization,
              user: settings.vm_shepherd.creds.user,
              password: settings.vm_shepherd.creds.password,
            },
            settings.vm_shepherd.vdc.name,
            error_logger
          ).destroy([settings.vm_shepherd.vapp.ops_manager_name], settings.vm_shepherd.vdc.catalog)
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::VsphereManager.new(
            settings.vm_shepherd.vcenter_creds.ip,
            settings.vm_shepherd.vcenter_creds.username,
            settings.vm_shepherd.vcenter_creds.password,
            settings.vm_shepherd.vsphere.datacenter,
          ).destroy(settings.vm_shepherd.vm.ip)
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.destroy
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          openstack_vm_manager.destroy(openstack_vm_options)
        else
          fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
    end

    def clean_environment
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          VmShepherd::VcloudManager.new(
            {
              url: settings.vm_shepherd.creds.url,
              organization: settings.vm_shepherd.creds.organization,
              user: settings.vm_shepherd.creds.user,
              password: settings.vm_shepherd.creds.password,
            },
            settings.vm_shepherd.vdc.name,
            error_logger,
          ).clean_environment(settings.vm_shepherd.vapp.product_names, settings.vm_shepherd.vapp.product_catalog)
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::VsphereManager.new(
            settings.vm_shepherd.vcenter_creds.ip,
            settings.vm_shepherd.vcenter_creds.username,
            settings.vm_shepherd.vcenter_creds.password,
            settings.vm_shepherd.cleanup.datacenter,
          ).clean_environment(
            datacenter_folders_to_clean: settings.vm_shepherd.cleanup.datacenter_folders_to_clean,
            datastores: settings.vm_shepherd.cleanup.datastores,
            datastore_folders_to_clean: settings.vm_shepherd.cleanup.datastore_folders_to_clean,
          )
        when VmShepherd::AWS_IAAS_TYPE then
          ami_manager.clean_environment
        when VmShepherd::OPENSTACK_IAAS_TYPE then
          openstack_vm_manager.clean_environment
        else
          fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
    end

    private

    attr_reader :settings

    def error_logger
      Logger.new(STDOUT).tap do |lggr|
        lggr.level = Logger::Severity::ERROR
      end
    end

    def vcloud_deploy_options
      vm = settings.vm_shepherd.vapp
      {
        name: vm.ops_manager_name,
        ip: vm.ip,
        gateway: vm.gateway,
        netmask: vm.netmask,
        dns: vm.dns,
        ntp: vm.ntp,
      }
    end

    def ami_manager
      vm_shepherd = settings.vm_shepherd
      VmShepherd::AwsManager.new(
        aws_access_key: vm_shepherd.aws_access_key,
        aws_secret_key: vm_shepherd.aws_secret_key,
        ssh_key_name: vm_shepherd.ssh_key_name,
        security_group_id: vm_shepherd.security_group,
        public_subnet_id: vm_shepherd.public_subnet_id,
        private_subnet_id: vm_shepherd.private_subnet_id,
        elastic_ip_id: vm_shepherd.elastic_ip_id,
        vm_name: vm_shepherd.vm_name,
      )
    end

    def openstack_vm_manager
      OpenstackManager.new(
        auth_url: settings.vm_shepherd.creds.auth_url,
        username: settings.vm_shepherd.creds.username,
        api_key: settings.vm_shepherd.creds.api_key,
        tenant: settings.vm_shepherd.creds.tenant,
      )
    end

    def openstack_vm_options
      {
        name: settings.vm_shepherd.vm.name,
        min_disk_size: settings.vm_shepherd.vm.flavor_parameters.min_disk_size,
        network_name: settings.vm_shepherd.vm.network_name,
        key_name: settings.vm_shepherd.vm.key_name,
        security_group_names: settings.vm_shepherd.vm.security_group_names,
        public_ip: settings.vm_shepherd.vm.public_ip,
        private_ip: settings.vm_shepherd.vm.private_ip,
      }
    end
  end
end
