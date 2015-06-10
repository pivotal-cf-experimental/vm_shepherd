require 'vm_shepherd/vsphere_manager'

module VmShepherd
  RSpec.describe VsphereManager do
    let(:host) { 'FAKE_VSPHERE_HOST' }
    let(:username) { 'FAKE_USERNAME' }
    let(:password) { 'FAKE_PASSWORD' }
    let(:datacenter_name) { 'FAKE_DATACENTER_NAME' }
    let(:vm1) { instance_double(RbVmomi::VIM::VirtualMachine, name: 'vm_name1', resourcePool: instance_double(RbVmomi::VIM::ResourcePool, name: 'first_resource_pool')) }
    let(:vm2) { instance_double(RbVmomi::VIM::VirtualMachine, name: 'vm_name2', resourcePool: instance_double(RbVmomi::VIM::ResourcePool, name: 'second_resource_pool')) }
    let(:vm3) { instance_double(RbVmomi::VIM::VirtualMachine, name: 'vm_name3', resourcePool: instance_double(RbVmomi::VIM::ResourcePool, name: 'second_resource_pool')) }
    let(:vms) { [vm1, vm2, vm3] }
    let(:fake_logger) { instance_double(Logger).as_null_object }

    subject(:vsphere_manager) { VsphereManager.new(host, username, password, datacenter_name, fake_logger) }

    it 'loads' do
      expect { vsphere_manager }.not_to raise_error
    end

    describe 'clean_environment' do
      let(:connection) { instance_double(RbVmomi::VIM, serviceContent: service_content, searchIndex: search_index)}
      let(:service_content) { instance_double(RbVmomi::VIM::ServiceContent, searchIndex: search_index)}
      let(:search_index) { instance_double(RbVmomi::VIM::SearchIndex) }
      let(:folder) {instance_double(RbVmomi::VIM::Folder) }
      let(:datacenter) { instance_double(RbVmomi::VIM::Datacenter, name: datacenter_name) }
      let(:filemanager) { instance_double(RbVmomi::VIM::FileManager) }
      let(:delete_datastore_file_task) { instance_double(RbVmomi::VIM::Task) }

      before do
        allow(vsphere_manager).to receive(:connection).and_return(connection)
        allow(folder).to receive(:traverse).and_return(folder)
        allow(connection).to receive(:searchIndex).and_return(search_index)
        allow(search_index).to receive(:FindByInventoryPath).with({inventoryPath: datacenter_name}).and_return(datacenter)
        allow(datacenter).to receive(:tap).and_return(datacenter)
        allow(datacenter).to receive(:vmFolder).and_return(folder)
        allow(folder).to receive(:traverse).with('FAKE_DATACENTER_FOLDERS').and_return(folder)
        allow(service_content).to receive(:fileManager).and_return(filemanager)
        # stubbed private methods:
        allow(subject).to receive(:find_vms).and_return(vms)
        allow(subject).to receive(:power_off_vm)
        allow(subject).to receive(:delete_folder_and_vms)
      end

      it 'should delete folders and vms' do
        expect(filemanager).to receive(:DeleteDatastoreFile_Task).and_return(delete_datastore_file_task)
        expect(delete_datastore_file_task).to receive(:wait_for_completion)
        vsphere_manager.clean_environment(datacenter_folders_to_clean: ['FAKE_DATACENTER_FOLDERS'], datastores: ['FAKE_DATASTORES'], datastore_folders_to_clean: ['FAKE_DATASTORE_FOLDERS'])
      end
    end

    describe 'destroy' do
      let(:search_index) { instance_double(RbVmomi::VIM::SearchIndex) }
      let(:service_content) { instance_double(RbVmomi::VIM::ServiceContent, searchIndex: search_index)}
      let(:connection) { instance_double(RbVmomi::VIM, serviceContent: service_content)}
      let(:ip_address) { '127.0.0.1' }

      before do
        allow(vsphere_manager).to receive(:connection).and_return(connection)
        allow(search_index).to receive(:FindAllByIp).with(ip: ip_address, vmSearch: true).and_return(vms)
      end

      it 'destroys the VM that matches the given ip address and resource pool' do
        expect(vsphere_manager).to receive(:power_off_vm).with(vm2)
        expect(vsphere_manager).to receive(:destroy_vm).with(vm2)

        expect(vsphere_manager).to receive(:power_off_vm).with(vm3)
        expect(vsphere_manager).to receive(:destroy_vm).with(vm3)

        vsphere_manager.destroy(ip_address, 'second_resource_pool')
      end

      it 'destroys the VM that matches the given ip address only when resource pool nil' do
        expect(vsphere_manager).to receive(:power_off_vm).with(vm1)
        expect(vsphere_manager).to receive(:destroy_vm).with(vm1)

        expect(vsphere_manager).to receive(:power_off_vm).with(vm2)
        expect(vsphere_manager).to receive(:destroy_vm).with(vm2)

        expect(vsphere_manager).to receive(:power_off_vm).with(vm3)
        expect(vsphere_manager).to receive(:destroy_vm).with(vm3)

        vsphere_manager.destroy(ip_address, nil)
      end

      context 'when there are no vms with that IP address' do
        let(:vms) { [] }

        it 'does not explode' do
          expect(vsphere_manager).not_to receive(:power_off_vm)
          expect(vsphere_manager).not_to receive(:destroy_vm)

          vsphere_manager.destroy(ip_address, 'second_resource_pool')
        end
      end

      context 'when there are no vms in that resource pool' do
        it 'does not explode' do
          expect(vsphere_manager).not_to receive(:power_off_vm)
          expect(vsphere_manager).not_to receive(:destroy_vm)

          vsphere_manager.destroy(ip_address, 'other_resource_pool')
        end
      end
    end

    describe 'destroy_vm' do
      let(:destroy_task) { instance_double(RbVmomi::VIM::Task) }

      before do
        allow(vm1).to receive(:Destroy_Task).and_return(destroy_task)
      end

      it 'runs the Destroy_Task and waits for completion' do
        expect(destroy_task).to receive(:wait_for_completion)

        vsphere_manager.destroy_vm(vm1)
      end
    end
  end
end
