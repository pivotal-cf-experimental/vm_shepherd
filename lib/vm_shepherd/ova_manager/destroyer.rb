require 'logger'

module VmShepherd
  module OvaManager
    class Destroyer
      def initialize(host, username, password, datacenter_name)
        @host = host
        @username = username
        @password = password
        @datacenter_name = datacenter_name
        @logger = Logger.new(STDERR)
      end

      def clean_folder(folder_name)
        delete_folder(folder_name)
        create_folder(folder_name)
      end

      private

      attr_reader :host, :username, :password, :datacenter_name, :logger

      def connection
        @connection ||= RbVmomi::VIM.connect(
          host: host,
          user: username,
          password: password,
          ssl: true,
          insecure: true,
        )
      end

      def datacenter
        @datacenter ||= begin
          match = connection.searchIndex.FindByInventoryPath(inventoryPath: datacenter_name)
          match if match and match.is_a?(RbVmomi::VIM::Datacenter)
        end
      end

      def create_folder(folder_name)
        raise ArgumentError unless folder_name_is_valid?(folder_name)
        raise ArgumentError if folder_exists?(folder_name)
        datacenter.vmFolder.traverse(folder_name, RbVmomi::VIM::Folder, true)
      end

      def delete_folder(folder_name)
        return unless (folder = find_folder(folder_name))

        find_vms(folder).each { |vm| power_off(vm) }

        logger.info("vm_folder_client.delete_folder.delete folder=#{folder_name}")
        folder.Destroy_Task.wait_for_completion
      rescue RbVmomi::Fault => e
        logger.error("vm_folder_client.delete_folder.failed folder=#{folder_name}")
        logger.error(e)
        raise
      end

      def power_off(vm)
        power_state = vm.runtime.powerState

        logger.info("vm_folder_client.delete_folder.power_off vm=#{vm.name} power_state=#{power_state}")

        unless power_state == 'poweredOff'
          # Trying to catch
          # 'InvalidPowerState: The attempted operation cannot be performed
          # in the current state (Powered off). (RbVmomi::Fault)'
          # (http://projects.puppetlabs.com/issues/16020)
          with_retry do
            logger.info("vm_folder_client.delete_folder.power_off vm=#{vm.name}")
            vm.PowerOffVM_Task.wait_for_completion
          end
        end
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

      def with_retry(tries=2, &blk)
        blk.call
      rescue StandardError => e
        tries -= 1
        if e.message.start_with?('InvalidPowerState') && tries > 0
          retry
        else
          raise
        end
      end
    end
  end
end
