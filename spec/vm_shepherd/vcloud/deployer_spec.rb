require 'vm_shepherd/data_object'
require 'vm_shepherd/vcloud/vapp_config'
require 'vm_shepherd/vcloud/deployer'
require 'ruby_vcloud_sdk'

module VmShepherd
  module Vcloud
    RSpec.describe Deployer do
      describe '.deploy_and_power_on_vapp' do
        let(:vapp_config) do
          VappConfig.new(
            name:    'NAME',
            ip:      'IP',
            gateway: 'GATEWAY',
            netmask: 'NETMASK',
            dns:     'DNS',
            ntp:     'NTP',
            catalog: 'CATALOG',
            network: 'NETWORK',
          )
        end

        let(:client) { instance_double(VCloudSdk::Client) }
        let(:catalog) { instance_double(VCloudSdk::Catalog) }
        let(:vapp) { instance_double(VCloudSdk::VApp) }
        let(:vm) { instance_double(VCloudSdk::VM) }
        let(:network_config) { instance_double(VCloudSdk::NetworkConfig) }

        before do
          allow(client).to receive(:create_catalog).and_return(catalog)
          allow(catalog).to receive(:upload_vapp_template)
          allow(catalog).to receive(:instantiate_vapp_template).and_return(vapp)
          allow(vapp).to receive_message_chain(:vms, :first).and_return(vm)
          allow(vm).to receive(:product_section_properties=)
          allow(vapp).to receive(:power_on)

          allow(VCloudSdk::NetworkConfig).to receive(:new).with('NETWORK', 'Network 1').and_return(network_config)
        end

        it 'creates a catalog' do
          expect(client).to receive(:create_catalog).with('CATALOG')

          Deployer.deploy_and_power_on_vapp(client: client, ovf_dir: nil, vapp_config: vapp_config, vdc_name: nil)
        end

        it 'uploads a vapp template' do
          expect(catalog).to receive(:upload_vapp_template).with('VDC_NAME', 'NAME', 'OVF_DIR')

          Deployer.deploy_and_power_on_vapp(client: client, ovf_dir: 'OVF_DIR', vapp_config: vapp_config, vdc_name: 'VDC_NAME')
        end

        it 'instantiates the template' do
          expect(catalog).to receive(:upload_vapp_template).with('VDC_NAME', 'NAME', 'OVF_DIR')
          expect(catalog).to receive(:instantiate_vapp_template).with('NAME', 'VDC_NAME', 'NAME', nil, nil, network_config)

          Deployer.deploy_and_power_on_vapp(client: client, ovf_dir: 'OVF_DIR', vapp_config: vapp_config, vdc_name: 'VDC_NAME')
        end

        it 'reconfigures the vm' do
          expect(vm).to receive(:product_section_properties=).with(vapp_config.build_properties)

          Deployer.deploy_and_power_on_vapp(client: client, ovf_dir: 'OVF_DIR', vapp_config: vapp_config, vdc_name: 'VDC_NAME')
        end

        it 'powers on the vapp' do
          expect(vapp).to receive(:power_on)

          Deployer.deploy_and_power_on_vapp(client: client, ovf_dir: 'OVF_DIR', vapp_config: vapp_config, vdc_name: 'VDC_NAME')
        end

        it 'does things in order' do
          Deployer.deploy_and_power_on_vapp(client: client, ovf_dir: 'OVF_DIR', vapp_config: vapp_config, vdc_name: 'VDC_NAME')

          expect(client).to have_received(:create_catalog).ordered
          expect(catalog).to have_received(:upload_vapp_template).ordered
          expect(catalog).to have_received(:instantiate_vapp_template).ordered
          expect(vm).to have_received(:product_section_properties=).ordered
          expect(vapp).to have_received(:power_on).ordered
        end
      end
    end
  end
end
