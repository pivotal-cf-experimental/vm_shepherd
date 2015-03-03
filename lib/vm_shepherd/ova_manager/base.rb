require 'rbvmomi'

module VmShepherd
  module OvaManager
    class Base
      attr_reader :vcenter

      def initialize(vcenter)
        @vcenter = vcenter
      end

      def find_datacenter(name)
        match = connection.searchIndex.FindByInventoryPath(inventoryPath: name)
        return unless match and match.is_a?(RbVmomi::VIM::Datacenter)
        match
      end

      private

      def connection
        @connection ||= RbVmomi::VIM.connect(
          host: @vcenter.fetch(:host),
          user: @vcenter.fetch(:user),
          password: @vcenter.fetch(:password),
          ssl: true,
          insecure: true,
        )
      end
    end
  end
end
