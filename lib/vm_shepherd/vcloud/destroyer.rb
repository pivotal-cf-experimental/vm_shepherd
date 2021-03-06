module VmShepherd
  module Vcloud
    class Destroyer
      def initialize(client:, vdc_name:)
        @client = client
        @vdc_name = vdc_name
      end

      def clean_catalog_and_vapps(catalog:, vapp_names:, logger:)
        clean_vapps(vapp_names, logger)
        delete_catalog(catalog)
      end

      private

      def vdc
        @vdc ||= @client.find_vdc_by_name(@vdc_name)
      end

      def clean_vapps(vapp_names, logger)
        vapp_names.each do |vapp_name|
          begin
            clean_vapp(vapp_name)
            delete_vapp(vapp_name)
          rescue VCloudSdk::ObjectNotFoundError => e
            logger.debug "Could not delete vapp '#{vapp_name}': #{e.inspect}"
          end
        end
      end

      def clean_vapp(vapp_name)
        vapp = vdc.find_vapp_by_name(vapp_name)
        vapp.vms.map do |vm|
          vm.independent_disks.map do |disk|
            vm.detach_disk(disk)
            vdc.delete_disk_by_name(disk.name)
          end
        end
      end

      def delete_vapp(vapp_name)
        vapp = vdc.find_vapp_by_name(vapp_name)

        if vapp.vms.any?
          vapp.power_off
          vapp.delete
        end
      end

      def delete_catalog(catalog)
        @client.delete_catalog_by_name(catalog) if @client.catalog_exists?(catalog)
      end
    end
  end
end
