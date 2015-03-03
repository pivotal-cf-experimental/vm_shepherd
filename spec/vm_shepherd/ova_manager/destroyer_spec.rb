require 'vm_shepherd/ova_manager/destroyer'

module VmShepherd
  module OvaManager
    RSpec.describe Destroyer do
      subject(:destroyer) { Destroyer.new('datacenter_name', vcenter_config) }
      let(:vcenter_config) { { host: 'host', user: 'user', password: 'password' } }

      describe '#clean_folder' do
        # Crappy temporary test to at least ensure that Destroyer requires the appropriate files
        it 'is wired up correctly' do
          connection = double('connection', serviceInstance: double('serviceInstance'))
          datacenter = double('datacenter')
          allow(datacenter).to receive(:is_a?).with(RbVmomi::VIM::Datacenter).and_return(true)
          vm_folder_client = double('vm_folder_client')

          expect(RbVmomi::VIM).to receive(:connect).with(
              host: 'host',
              user: 'user',
              password: 'password',
              ssl: true,
              insecure: true,
            ).and_return(connection)
          expect(connection).to receive(:searchIndex).and_return(
              double(:searchIndex).tap do |search_index|
                expect(search_index).to receive(:FindByInventoryPath).
                    with(inventoryPath: 'datacenter_name').
                    and_return(datacenter)
              end
            )
          expect(VsphereClients::VmFolderClient).to receive(:new).
              with(datacenter, instance_of(Logger)).
              and_return(vm_folder_client)
          expect(vm_folder_client).to receive(:delete_folder).with('folder_name')
          expect(vm_folder_client).to receive(:create_folder).with('folder_name')

          destroyer.clean_folder('folder_name')
        end
      end
    end
  end
end
