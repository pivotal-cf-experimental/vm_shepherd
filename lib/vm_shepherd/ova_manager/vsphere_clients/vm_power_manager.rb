module VsphereClients
  class VmPowerManager
    def initialize(vm, logger)
      @vm = vm
      @logger = logger
    end

    def power_off
      power_state = @vm.runtime.powerState

      @logger.info("vm_folder_client.delete_folder.power_off vm=#{@vm.name} power_state=#{power_state}")

      unless power_state == 'poweredOff'
        # Trying to catch
        # 'InvalidPowerState: The attempted operation cannot be performed
        # in the current state (Powered off). (RbVmomi::Fault)'
        # (http://projects.puppetlabs.com/issues/16020)
        with_retry do
          @logger.info("vm_folder_client.delete_folder.power_off vm=#{@vm.name}")
          @vm.PowerOffVM_Task.wait_for_completion
        end
      end
    end

    private

    def with_retry(tries=2, &blk)
      blk.call
    rescue Exception => e
      tries -= 1
      if e.message.start_with?('InvalidPowerState') && tries > 0
        retry
      else
        raise
      end
    end
  end
end
