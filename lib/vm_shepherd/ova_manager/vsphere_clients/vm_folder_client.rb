require 'rbvmomi'
require 'vm_shepherd/ova_manager/vsphere_clients/vm_power_manager'

module VsphereClients
  class VmFolderClient
    def initialize(vcenter_ip, username, password, datacenter_name, datastore_name, logger)
      puts "vcenterIP: #{vcenter_ip}"
      @vcenter_ip = vcenter_ip
      @username = username
      @password = password
      @datacenter_name = datacenter_name
      @datastore_name = datastore_name
      @logger = logger
    end

    def create_folder(folder_name)
      raise ArgumentError unless folder_name_is_valid?(folder_name)
      raise ArgumentError if folder_exists?(folder_name)
      datacenter.vmFolder.traverse(folder_name, RbVmomi::VIM::Folder, true)
    end

    def delete_folder(folder_name)
      return unless (folder = find_folder(folder_name))

      find_vms(folder).each { |vm| VmPowerManager.new(vm, @logger).power_off }

      @logger.info("vm_folder_client.delete_folder.delete folder=#{folder_name}")
      folder.Destroy_Task.wait_for_completion
    rescue RbVmomi::Fault => e
      @logger.error("vm_folder_client.delete_folder.failed folder=#{folder_name}")
      @logger.error(e)
      raise
    end

    def datacenter
      @datacenter ||= begin
        match = connection.searchIndex.FindByInventoryPath(inventoryPath: @datacenter_name)
        match if match and match.is_a?(RbVmomi::VIM::Datacenter)
      end
    end

    private

    def connection
      @connection ||= RbVmomi::VIM.connect(
        host: @vcenter_ip,
        user: @username,
        password: @password,
        ssl: true,
        insecure: true,
      )
    end

    def folder_exists?(folder_name)
      !find_folder(folder_name).nil?
    end

    def find_folder(folder_name)
      raise ArgumentError unless folder_name_is_valid?(folder_name)
      datacenter.vmFolder.traverse(folder_name)
    end

    def find_vms(folder)
      vms = folder.childEntity.grep(RbVmomi::VIM::VirtualMachine)
      vms << folder.childEntity.grep(RbVmomi::VIM::Folder).map { |child| find_vms(child) }
      vms.flatten
    end

    def folder_name_is_valid?(folder_name)
      /\A([\w-]{1,80}\/)*[\w-]{1,80}\/?\z/.match(folder_name)
    end
  end
end
