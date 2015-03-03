require 'vm_shepherd/vapp_manager/destroyer'

module VmShepherd
  module VappManager
    RSpec.describe Destroyer do
      let(:login_info) do
        {
          url: 'FAKE_URL',
          organization: 'FAKE_ORGANIZATION',
          user: 'FAKE_USER',
          password: 'FAKE_PASSWORD',
        }
      end
      let(:location) do
        {
          catalog: 'FAKE_CATALOG',
          vdc: 'FAKE_VDC',
        }
      end
      let(:logger) { instance_double(Logger).as_null_object }

      let(:destroyer) { Destroyer.new(login_info, location, logger) }

      describe '#destroy' do
        let(:client) { instance_double(VCloudSdk::Client) }
        let(:vdc) { instance_double(VCloudSdk::VDC) }
        let(:vapp) { instance_double(VCloudSdk::VApp) }
        let(:vapp_name) { 'FAKE_VAPP_NAME' }

        context 'when the catalog exists' do
          before do
            allow(client).to receive(:catalog_exists?).with(location.fetch(:catalog)).and_return(true)
          end

          it 'uses VCloudSdk::Client to delete the vApp' do
            expect(client).to receive(:find_vdc_by_name).with(location.fetch(:vdc)).and_return(vdc)
            expect(vdc).to receive(:find_vapp_by_name).with(vapp_name).and_return(vapp)
            expect(vapp).to receive(:power_off)
            expect(vapp).to receive(:delete)
            expect(client).to receive(:delete_catalog_by_name).with(location.fetch(:catalog))

            expect(VCloudSdk::Client).to receive(:new).with(
                login_info.fetch(:url),
                [login_info.fetch(:user), login_info.fetch(:organization)].join('@'),
                login_info.fetch(:password),
                {},
                logger,
              ).and_return(client)

            destroyer.destroy(vapp_name)
          end

          context 'when an VCloudSdk::ObjectNotFoundError is thrown' do
            before do
              allow(VCloudSdk::Client).to receive(:new).and_return(client)
              allow(client).to receive(:find_vdc_by_name).and_return(vdc)
              allow(vdc).to receive(:find_vapp_by_name).and_return(vapp)
              allow(vapp).to receive(:power_off)
              allow(vapp).to receive(:delete)

              allow(client).to receive(:delete_catalog_by_name)
            end

            it 'catches the error' do
              allow(client).to receive(:find_vdc_by_name).and_raise(VCloudSdk::ObjectNotFoundError)

              expect { destroyer.destroy(vapp_name) }.not_to raise_error
            end

            it 'deletes to catalog' do
              expect(client).to receive(:delete_catalog_by_name).with(location.fetch(:catalog))

              destroyer.destroy(vapp_name)
            end
          end
        end

        context 'when the catalog does not exist' do
          before do
            allow(client).to receive(:catalog_exists?).with(location.fetch(:catalog)).and_return(false)
          end

          it 'uses VCloudSdk::Client to delete the vApp' do
            expect(client).to receive(:find_vdc_by_name).with(location.fetch(:vdc)).and_return(vdc)
            expect(vdc).to receive(:find_vapp_by_name).with(vapp_name).and_return(vapp)
            expect(vapp).to receive(:power_off)
            expect(vapp).to receive(:delete)
            expect(client).not_to receive(:delete_catalog_by_name).with(location.fetch(:catalog))

            expect(VCloudSdk::Client).to receive(:new).with(
                login_info.fetch(:url),
                [login_info.fetch(:user), login_info.fetch(:organization)].join('@'),
                login_info.fetch(:password),
                {},
                logger,
              ).and_return(client)

            destroyer.destroy(vapp_name)
          end
        end
      end
    end
  end
end
