require 'vm_shepherd/ova_manager/destroyer'

module VmShepherd
  module OvaManager
    RSpec.describe Destroyer do
      subject(:destroyer) { Destroyer.new('datacenter_name', vcenter_config) }
      let(:vcenter_config) { {host: 'host', user: 'user', password: 'password'} }
      let(:vm_folder_client) { instance_double(VsphereClients::VmFolderClient) }

      describe '#clean_folder' do
        it 'is wired up correctly' do
          expect(VsphereClients::VmFolderClient).to receive(:new).with(
              vcenter_config[:host],
              vcenter_config[:user],
              vcenter_config[:password],
              'datacenter_name',
              instance_of(Logger),
            ).and_return(vm_folder_client)

          expect(vm_folder_client).to receive(:delete_folder).with('folder_name')
          expect(vm_folder_client).to receive(:create_folder).with('folder_name')

          destroyer.clean_folder('folder_name')
        end
      end
    end
  end
end
