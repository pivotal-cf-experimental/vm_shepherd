module VmShepherd
  class Shepherd
    VSPHERE_TEMPLATE_PREFIX = 'tpl'.freeze

    class InvalidIaas < StandardError

    end

    def initialize(settings:)
      @settings = settings
    end

    def deploy(path:)
      case settings.iaas_type
        when VmShepherd::VCLOUD_IAAS_TYPE then
          creds = settings.vapp_deployer.creds
          vdc = settings.vapp_deployer.vdc
          VmShepherd::VcloudManager.new(
            {
              url: creds.url,
              organization: creds.organization,
              user: creds.user,
              password: creds.password,
            },
            {
              vdc: vdc.name,
              catalog: vdc.catalog,
              network: vdc.network,
            },
            debug_logger
          ).deploy(
            path,
            vcloud_deploy_options,
          )
        when VmShepherd::VSPHERE_IAAS_TYPE then
          vm_deployer_settings = settings.vm_deployer
          VmShepherd::OvaManager.new(
            vm_deployer_settings.vcenter_creds.ip,
            vm_deployer_settings.vcenter_creds.username,
            vm_deployer_settings.vcenter_creds.password,
            vm_deployer_settings.vsphere.datacenter,
          ).deploy(
            VSPHERE_TEMPLATE_PREFIX,
            path,
            {
              ip: vm_deployer_settings.vm.ip,
              gateway: vm_deployer_settings.vm.gateway,
              netmask: vm_deployer_settings.vm.netmask,
              dns: vm_deployer_settings.vm.dns,
              ntp_servers: vm_deployer_settings.vm.ntp_servers,
            },
            {
              cluster: vm_deployer_settings.vsphere.cluster,
              resource_pool: vm_deployer_settings.vsphere.resource_pool,
              datastore: vm_deployer_settings.vsphere.datastore,
              network: vm_deployer_settings.vsphere.network,
              folder: vm_deployer_settings.vsphere.folder,
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
            },
            Logger.new(STDOUT).tap { |l| l.level = Logger::Severity::ERROR }
          ).destroy(settings.vapp_deployer.vapp.name)
        when VmShepherd::VSPHERE_IAAS_TYPE then
          VmShepherd::OvaManager.new(
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
      VmShepherd::AmiManager.new(
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
