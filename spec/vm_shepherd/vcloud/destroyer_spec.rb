require 'vm_shepherd/data_object'
require 'vm_shepherd/vcloud/vapp_config'
require 'vm_shepherd/vcloud/destroyer'
require 'ruby_vcloud_sdk'

module VmShepherd
  module Vcloud
    RSpec.describe Destroyer do
      subject(:destroyer) { Destroyer.new(client: client, vdc_name: vdc_name) }
      let(:client) { instance_double(VCloudSdk::Client) }
      let(:vdc_name) { 'VDC_NAME' }
      let(:fake_logger) { double(:logger, debug: nil) }
      let(:vm) { instance_double(VCloudSdk::VM) }
      let(:vdc) { instance_double(VCloudSdk::VDC) }
      let(:vapp) { instance_double(VCloudSdk::VApp) }
      let(:disk) { instance_double(VCloudSdk::InternalDisk, name: 'DISK_NAME') }

      before do
        allow(client).to receive(:delete_catalog_by_name)
        allow(client).to receive(:catalog_exists?)
        allow(client).to receive(:find_vdc_by_name).with(vdc_name).and_return(vdc)
        allow(vdc).to receive(:find_vapp_by_name).with('VAPP_NAME').and_return(vapp)
        allow(vdc).to receive(:delete_disk_by_name)
        allow(vapp).to receive(:vms).and_return([vm])
        allow(vapp).to receive(:power_off)
        allow(vapp).to receive(:delete)
        allow(vm).to receive(:independent_disks).and_return([disk])
        allow(vm).to receive(:detach_disk)
      end

      describe '#clean_catalog_and_vapps' do
        context 'when the catalog exists' do
          before do
            allow(client).to receive(:catalog_exists?).with('CATALOG_NAME').and_return(true)
          end

          it 'deletes the catalog' do
            destroyer.clean_catalog_and_vapps(catalog: 'CATALOG_NAME', vapp_names: [], logger: fake_logger, delete_vapps: false)

            expect(client).to have_received(:delete_catalog_by_name).with('CATALOG_NAME')
          end
        end

        context 'when the catalog does not exist' do
          before do
            allow(client).to receive(:catalog_exists?).with('CATALOG_NAME').and_return(false)
          end

          it 'skips deleting the catalog' do
            destroyer.clean_catalog_and_vapps(catalog: 'CATALOG_NAME', vapp_names: [], logger: fake_logger, delete_vapps: false)

            expect(client).not_to have_received(:delete_catalog_by_name).with('CATALOG_NAME')
          end
        end

        it 'detaches and deletes persistent disks' do
          destroyer.clean_catalog_and_vapps(catalog: 'CATALOG_NAME', vapp_names: ['VAPP_NAME'], logger: fake_logger, delete_vapps: false)

          expect(vm).to have_received(:detach_disk).with(disk)
          expect(vdc).to have_received(:delete_disk_by_name).with('DISK_NAME')
        end

        context 'when the delete_vapps flag is true' do
          it 'deletes the vapps' do
            destroyer.clean_catalog_and_vapps(catalog: 'CATALOG_NAME', vapp_names: ['VAPP_NAME'], logger: fake_logger, delete_vapps: true)

            expect(vapp).to have_received(:power_off).ordered
            expect(vapp).to have_received(:delete).ordered
          end
        end

        context 'when the delete_vapps flag is false' do
          it 'does not delete the vapps' do
            destroyer.clean_catalog_and_vapps(catalog: 'CATALOG_NAME', vapp_names: ['VAPP_NAME'], logger: fake_logger, delete_vapps: false)

            expect(vapp).not_to have_received(:power_off)
            expect(vapp).not_to have_received(:delete)
          end
        end
      end
    end
  end
end
