module VmShepherd
  class Shepherd
    class InvalidIaas < StandardError

    end

    def initialize(settings:)
      @settings = settings
    end

    def deploy(path:)
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          VmShepherd::VcloudManager.new(
            {
              url: settings.vapp_deployer.creds.url,
              organization: settings.vapp_deployer.creds.organization,
              user: settings.vapp_deployer.creds.user,
              password: settings.vapp_deployer.creds.password,
            },
            {
              vdc: settings.vapp_deployer.vdc.name,
              catalog: settings.vapp_deployer.vdc.catalog,
              network: settings.vapp_deployer.vdc.network,
            },
            debug_logger
          ).deploy(
            path,
            vcloud_deploy_options,
          )
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::VsphereManager.new(
            settings.vm_deployer.vcenter_creds.ip,
            settings.vm_deployer.vcenter_creds.username,
            settings.vm_deployer.vcenter_creds.password,
            settings.vm_deployer.vsphere.datacenter,
          ).deploy(
            path,
            {
              ip: settings.vm_deployer.vm.ip,
              gateway: settings.vm_deployer.vm.gateway,
              netmask: settings.vm_deployer.vm.netmask,
              dns: settings.vm_deployer.vm.dns,
              ntp_servers: settings.vm_deployer.vm.ntp_servers,
            },
            {
              cluster: settings.vm_deployer.vsphere.cluster,
              resource_pool: settings.vm_deployer.vsphere.resource_pool,
              datastore: settings.vm_deployer.vsphere.datastore,
              network: settings.vm_deployer.vsphere.network,
              folder: settings.vm_deployer.vsphere.folder,
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
              url: settings.vapp_deployer.creds.url,
              organization: settings.vapp_deployer.creds.organization,
              user: settings.vapp_deployer.creds.user,
              password: settings.vapp_deployer.creds.password,
            },
            {
              vdc: settings.vapp_deployer.vdc.name,
              catalog: settings.vapp_deployer.vdc.catalog,
              network: settings.vapp_deployer.vdc.network,
            },
            logger
          ).destroy([settings.vapp_deployer.vapp.ops_manager_name] + settings.vapp_deployer.vapp.product_names)
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::VsphereManager.new(
            settings.vm_deployer.vcenter_creds.ip,
            settings.vm_deployer.vcenter_creds.username,
            settings.vm_deployer.vcenter_creds.password,
            settings.vm_deployer.vsphere.datacenter,
          ).destroy(settings.vm_deployer.vsphere.folder)
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
              url: settings.vapp_deployer.creds.url,
              organization: settings.vapp_deployer.creds.organization,
              user: settings.vapp_deployer.creds.user,
              password: settings.vapp_deployer.creds.password,
            },
            {
              vdc: settings.vapp_deployer.vdc.name,
              catalog: settings.vapp_deployer.vdc.catalog,
              network: settings.vapp_deployer.vdc.network,
            },
            logger
          ).clean_environment
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::VsphereManager.new(
            settings.vm_deployer.vcenter_creds.ip,
            settings.vm_deployer.vcenter_creds.username,
            settings.vm_deployer.vcenter_creds.password,
            settings.vm_deployer.vsphere.datacenter,
          ).clean_environment(
            datacenter_folders_to_clean: settings.vm_deployer.vsphere.datacenter_folders_to_clean,
            datastore: settings.vm_deployer.vsphere.datastore,
            datastore_folders_to_clean: settings.vm_deployer.vsphere.datastore_folders_to_clean,
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

    def logger
      Logger.new(STDOUT).tap do |lggr|
        lggr.level = Logger::Severity::ERROR
      end
    end

    def debug_logger
      Logger.new(STDOUT).tap do |lggr|
        lggr.level = Logger::Severity::DEBUG
      end
    end

    def vcloud_deploy_options
      vm = settings.vapp_deployer.vapp
      {
        name: vm.name,
        ip: vm.ip,
        gateway: vm.gateway,
        netmask: vm.netmask,
        dns: vm.dns,
        ntp: vm.ntp,
      }
    end

    def ami_manager
      vm_deployer = settings.vm_deployer
      VmShepherd::AwsManager.new(
        aws_access_key: vm_deployer.aws_access_key,
        aws_secret_key: vm_deployer.aws_secret_key,
        ssh_key_name: vm_deployer.ssh_key_name,
        security_group_id: vm_deployer.security_group,
        public_subnet_id: vm_deployer.public_subnet_id,
        private_subnet_id: vm_deployer.private_subnet_id,
        elastic_ip_id: vm_deployer.elastic_ip_id,
        vm_name: vm_deployer.vm_name,
      )
    end

    def openstack_vm_manager
      OpenstackManager.new(
        auth_url: settings.vm_deployer.creds.auth_url,
        username: settings.vm_deployer.creds.username,
        api_key: settings.vm_deployer.creds.api_key,
        tenant: settings.vm_deployer.creds.tenant,
      )
    end

    def openstack_vm_options
      {
        name: settings.vm_deployer.vm.name,
        min_disk_size: settings.vm_deployer.vm.flavor_parameters.min_disk_size,
        network_name: settings.vm_deployer.vm.network_name,
        key_name: settings.vm_deployer.vm.key_name,
        security_group_names: settings.vm_deployer.vm.security_group_names,
        public_ip: settings.vm_deployer.vm.public_ip,
        private_ip: settings.vm_deployer.vm.private_ip,
      }
    end
  end
end
