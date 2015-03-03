require 'ruby_vcloud_sdk'

module VmShepherd
  module VappManager
    class Destroyer
      def initialize(login_info, location, logger)
        @login_info = login_info
        @location = location
        @logger = logger
      end

      def destroy(vapp_name)
        delete_vapp(vapp_name)
        delete_catalog
      end

      private

      def client
        @client ||= VCloudSdk::Client.new(
          @login_info[:url],
          "#{@login_info[:user]}@#{@login_info[:organization]}",
          @login_info[:password],
          {},
          @logger,
        )
      end

      def vdc
        @vdc ||= client.find_vdc_by_name(@location[:vdc])
      end

      def delete_vapp(vapp_name)
        vapp = vdc.find_vapp_by_name(vapp_name)
        vapp.power_off
        vapp.delete
      rescue VCloudSdk::ObjectNotFoundError => e
        @logger.debug "Could not delete vapp '#{vapp_name}': #{e.inspect}"
      end

      def delete_catalog
        client.delete_catalog_by_name(@location[:catalog]) if client.catalog_exists?(@location[:catalog])
      end
    end
  end
end
