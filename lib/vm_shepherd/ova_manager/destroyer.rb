require 'logger'
require 'vm_shepherd/ova_manager/vsphere_clients/vm_folder_client'

module VmShepherd
  module OvaManager
    class Destroyer
      def initialize(host, username, password, datacenter_name)
        @host = host
        @username = username
        @password = password
        @datacenter_name = datacenter_name
      end

      def clean_folder(folder_name)
        vm_folder_client.delete_folder(folder_name)
        vm_folder_client.create_folder(folder_name)
      end

      private

      attr_reader :host, :username, :password, :datacenter_name

      def vm_folder_client
        @vm_folder_client ||= VsphereClients::VmFolderClient.new(
          host,
          username,
          password,
          datacenter_name,
          Logger.new(STDERR)
        )
      end
    end
  end
end
