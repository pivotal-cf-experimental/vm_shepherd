require 'vm_shepherd/vapp_manager/deployer'
require 'vm_shepherd/vapp_manager/destroyer'
require 'vm_shepherd/ova_manager/deployer'
require 'vm_shepherd/ova_manager/destroyer'
require 'vm_shepherd/ami_manager'

module VmShepherd
  class Shepherd
    VCLOUD_IAAS_TYPE = 'vcloud'.freeze
    VSPHERE_IAAS_TYPE = 'vsphere'.freeze
    AWS_IAAS_TYPE = 'aws'.freeze
    VSPHERE_TEMPLATE_PREFIX = 'tpl'.freeze

    class InvalidIaas < StandardError

    end

    def initialize(settings:)
      @settings = settings
    end

    def deploy(path:)
      case settings.iaas_type
        when VCLOUD_IAAS_TYPE then
          vcloud_deployer.deploy(
            path,
            vcloud_deploy_options,
          )
        when VSPHERE_IAAS_TYPE then
          vsphere_deployer.deploy(
            VSPHERE_TEMPLATE_PREFIX,
            path,
            vsphere_deploy_options,
          )
        when AWS_IAAS_TYPE then
          ami_manager.deploy(path)
        else
          fail(InvalidIaas, "Unknown IaaS type: #{settings.iaas_type.inspect}")
      end
    end

    def destroy
      case settings.iaas_type
        when VCLOUD_IAAS_TYPE then
          VmShepherd::VappManager::Destroyer.new(
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
        when VSPHERE_IAAS_TYPE then
          VmShepherd::OvaManager::Destroyer.new(
            settings.vm_deployer.vsphere.datacenter,
            {
              host: settings.vm_deployer.vcenter_creds.ip,
              user: settings.vm_deployer.vcenter_creds.username,
              password: settings.vm_deployer.vcenter_creds.password,
            }
          ).clean_folder(settings.vm_deployer.vsphere.folder)
        when AWS_IAAS_TYPE then
          ami_manager.destroy
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

    def vcloud_deployer
      creds = settings.vapp_deployer.creds
      vdc = settings.vapp_deployer.vdc
      VmShepherd::VappManager::Deployer.new(
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
      )
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

    def vsphere_deployer
      vcenter_creds = settings.vm_deployer.vcenter_creds
      vsphere = settings.vm_deployer.vsphere
      VmShepherd::OvaManager::Deployer.new(
        {
          host: vcenter_creds.ip,
          user: vcenter_creds.username,
          password: vcenter_creds.password,
        },
        {
          datacenter: vsphere.datacenter,
          cluster: vsphere.cluster,
          resource_pool: vsphere.resource_pool,
          datastore: vsphere.datastore,
          network: vsphere.network,
          folder: vsphere.folder,
        }
      )
    end

    def vsphere_deploy_options
      vm = settings.vm_deployer.vm
      {
        ip: vm.ip,
        gateway: vm.gateway,
        netmask: vm.netmask,
        dns: vm.dns,
        ntp_servers: vm.ntp_servers,
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
  end
end
