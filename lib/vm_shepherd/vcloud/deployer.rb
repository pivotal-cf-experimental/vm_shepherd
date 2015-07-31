module VmShepherd
  module Vcloud
    class Deployer
      def self.deploy_and_power_on_vapp(client:, ovf_dir:, vapp_config:, vdc_name:)
        catalog = client.create_catalog(vapp_config.catalog)

        # upload template and instantiate vapp
        catalog.upload_vapp_template(vdc_name, vapp_config.name, ovf_dir)

        # instantiate template
        network_config                = VCloudSdk::NetworkConfig.new(vapp_config.network, 'Network 1')
        vapp                          = catalog.instantiate_vapp_template(vapp_config.name, vdc_name, vapp_config.name, nil, nil, network_config)

        # reconfigure vm
        vm                            = vapp.find_vm_by_name(vapp_config.name)
        vm.product_section_properties = vapp_config.build_properties

        # power on vapp
        vapp.power_on
      end
    end
  end
end
