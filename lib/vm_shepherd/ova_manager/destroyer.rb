require 'logger'
require 'vm_shepherd/ova_manager/vsphere_clients/vm_folder_client'

module VmShepherd
  module OvaManager
    class Destroyer
      def initialize(datacenter_name, vcenter)
        @datacenter_name = datacenter_name
        @vcenter = vcenter
      end

      def clean_folder(folder_name)
        vm_folder_client.delete_folder(folder_name)
        vm_folder_client.create_folder(folder_name)
      end

      private

      def vm_folder_client
        @vm_folder_client ||= VsphereClients::VmFolderClient.new(
          @vcenter[:host],
          @vcenter[:user],
          @vcenter[:password],
          @datacenter_name,
          Logger.new(STDERR)
        )
      end
    end
  end
end
