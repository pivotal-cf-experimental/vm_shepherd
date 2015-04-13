require 'vm_shepherd/vsphere_manager'

module VmShepherd
  RSpec.describe VsphereManager do
    let(:host) { 'FAKE_VSPHERE_HOST' }
    let(:username) { 'FAKE_USERNAME' }
    let(:password) { 'FAKE_PASSWORD' }
    let(:datacenter_name) { 'FAKE_DATACENTER_NAME' }
    let(:vm) { instance_double(RbVmomi::VIM::VirtualMachine, name: 'vm_name') }

    subject(:vsphere_manager) do
      manager = VsphereManager.new(host, username, password, datacenter_name)
      manager.logger = Logger.new(StringIO.new)
      manager
    end

    it 'loads' do
      expect { vsphere_manager }.not_to raise_error
    end

    describe 'destroy' do
      let(:datacenter) { instance_double(RbVmomi::VIM::Datacenter, vmFolder: vm_folder) }
      let(:vm_folder) { instance_double(RbVmomi::VIM::Folder) }
      let(:ip_address) { '127.0.0.1' }

      before do
        allow(vsphere_manager).to receive(:datacenter).and_return(datacenter)
        allow(vm_folder).to receive(:findByIp).with(ip_address).and_return(vm)
      end

      it 'destroys the VM that matches the given ip address' do
        expect(vsphere_manager).to receive(:power_off_vm).with(vm)
        expect(vsphere_manager).to receive(:destroy_vm).with(vm)

        vsphere_manager.destroy(ip_address)
      end

      context 'when the vm does not exist' do
        before do
          allow(vm_folder).to receive(:findByIp).and_return(nil)
        end

        it 'does not explode' do
          expect(vsphere_manager).not_to receive(:power_off_vm)
          expect(vsphere_manager).not_to receive(:destroy_vm)

          vsphere_manager.destroy(ip_address)
        end
      end
    end

    describe 'destroy_vm' do
      let(:destroy_task) { instance_double(RbVmomi::VIM::Task) }

      before do
        allow(vm).to receive(:Destroy_Task).and_return(destroy_task)
      end

      it 'runs the Destroy_Task and waits for completion' do
        expect(destroy_task).to receive(:wait_for_completion)

        vsphere_manager.destroy_vm(vm)
      end
    end
  end
end
