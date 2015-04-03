require 'vm_shepherd/vsphere_manager'

module VmShepherd
  RSpec.describe VsphereManager do
    let(:host) { 'FAKE_VSPHERE_HOST' }
    let(:username) { 'FAKE_USERNAME' }
    let(:password) { 'FAKE_PASSWORD' }
    let(:datacenter_name) { 'FAKE_DATACENTER_NAME' }

    subject(:vsphere_manager) { VsphereManager.new(host, username, password, datacenter_name) }

    it 'loads' do
      expect { vsphere_manager }.not_to raise_error
    end
  end
end
