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
    let(:task) { instance_double(RbVmomi::VIM::Task) }
    let(:fake_logger) { instance_double(Logger).as_null_object }
    let(:datacenter) do
      instance_double(RbVmomi::VIM::Datacenter,
        name: datacenter_name,
        vmFolder: folder,
        find_compute_resource: cluster,
        find_datastore: datastore
      )
    end
    let(:datastore) { double(name: datastore_name) }
    let(:datastore_name) { 'datastore-name' }
    let(:cluster) { instance_double(RbVmomi::VIM::ComputeResource, name: 'cluster-name', host: [host], resourcePool: double)}
    let(:folder) { instance_double(RbVmomi::VIM::Folder, traverse: instance_double(RbVmomi::VIM::Folder)) }
    let(:connection) { instance_double(RbVmomi::VIM, serviceContent: service_content, searchIndex: search_index) }
    let(:service_content) do
      instance_double(RbVmomi::VIM::ServiceContent,
        searchIndex: search_index,
        ovfManager: ovf_manager,
        propertyCollector: instance_double(RbVmomi::VIM::PropertyCollector, collectMultiple: {}),
      )
    end
    let(:search_index) { instance_double(RbVmomi::VIM::SearchIndex) }
    let(:ovf_manager) { instance_double(RbVmomi::VIM::OvfManager) }

    subject(:vsphere_manager) { VsphereManager.new(host, username, password, datacenter_name, fake_logger) }

    it 'loads' do
      expect { vsphere_manager }.not_to raise_error
    end

    describe 'deploy' do
      let(:tar_path) { 'example-tar' }
      let(:ova_path) { 'example-ova' }
      let(:folder_name) { 'example-folder' }
      let(:ovf_template) { instance_double(RbVmomi::VIM::VirtualMachine, name: 'vm_name', add_delta_disk_layer_on_all_disks: nil, MarkAsTemplate: nil) }
      let(:vsphere_config) { { folder: folder_name, datastore: datastore_name } }
      let(:vm_config) { {ip: '10.0.0.1'} }

      before do
        allow(vsphere_manager).to receive(:system).with("nc -z -w 1 #{vm_config[:ip]} 443").and_return(false)
        allow(vsphere_manager).to receive(:system).with(/tar xfv/).and_return(true)
        allow(Dir).to receive(:[]).and_return(['foo.ovf'])
        allow(vsphere_manager).to receive(:datacenter).and_return(datacenter)
        allow(vsphere_manager).to receive(:connection).and_return(connection)
        allow(ovf_manager).to receive(:deployOVF).and_return(ovf_template)
        allow(vsphere_manager).to receive(:ovf_template_options).and_return({})
      end

      context 'When custom hostname is not set' do
        it 'verifies the value of custom hostname is nil' do
          expect(vsphere_manager).to receive(:create_vm_from_template).and_return(vm1)
          allow(subject).to receive(:power_on_vm)
          allow(task).to receive(:wait_for_completion)

          expect(vm1).to receive(:ReconfigVM_Task) do |options|
            custom_hostname_property = options[:spec].vAppConfig.property.find do |prop|
              prop.instance_variable_get(:@props)[:info].instance_variable_get(:@props)[:label] == 'custom_hostname'
            end
            expect(custom_hostname_property).to be_nil
            task
          end

          subject.deploy(ova_path, vm_config, vsphere_config)
        end
      end

      context 'When custom hostname is set' do
        let(:vm_config) { {ip: '10.0.0.1', custom_hostname: 'meow' } }
        it 'sets the custom hostname' do
          expect(vsphere_manager).to receive(:create_vm_from_template).and_return(vm1)
          allow(subject).to receive(:power_on_vm)
          allow(task).to receive(:wait_for_completion)

          expect(vm1).to receive(:ReconfigVM_Task) do |options|
            custom_hostname_property = options[:spec].vAppConfig.property.find do |prop|
              prop.instance_variable_get(:@props)[:info].instance_variable_get(:@props)[:label] == 'custom_hostname'
            end
            expect(custom_hostname_property).to_not be_nil
            custom_hostname_value = custom_hostname_property.instance_variable_get(:@props)[:info].instance_variable_get(:@props)[:value]
            expect(custom_hostname_value).to eq('meow')
            task
          end

          subject.deploy(ova_path, vm_config, vsphere_config)
        end
      end
    end

    describe 'clean_environment' do

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
        allow(filemanager).to receive(:is_a?).with(RbVmomi::VIM::FileManager).and_return(true)
        # stubbed private methods:
        allow(subject).to receive(:find_vms).and_return(vms)
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
      let(:service_content) { instance_double(RbVmomi::VIM::ServiceContent, searchIndex: search_index) }
      let(:connection) { instance_double(RbVmomi::VIM, serviceContent: service_content) }
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
