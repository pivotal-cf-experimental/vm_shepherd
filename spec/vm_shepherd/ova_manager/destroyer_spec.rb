require 'vm_shepherd/ova_manager/destroyer'

module VmShepherd
  module OvaManager
    RSpec.describe Destroyer do
      let(:host) { 'FAKE_HOST' }
      let(:username) { 'FAKE_USERNAME' }
      let(:password) { 'FAKE_PASSWORD' }
      let(:datacenter) { 'FAKE_DATACENTER' }

      let(:vm_folder_client) { instance_double(VsphereClients::VmFolderClient) }

      subject(:destroyer) { Destroyer.new(host, username, password, datacenter) }

      describe '#clean_folder' do
        it 'is wired up correctly' do
          expect(VsphereClients::VmFolderClient).to receive(:new).with(
              host,
              username,
              password,
              datacenter,
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
