require 'spec_helper'
require 'vm_shepherd/ova_manager/vsphere_clients/vm_folder_client'

module VsphereClients
  RSpec.describe VmFolderClient do
    TEST_PLAYGROUND_FOLDER = 'vm_folder_client_spec_playground'

    let(:parent_folder) { "#{TEST_PLAYGROUND_FOLDER}/foo" }
    let(:nested_folder) { "#{parent_folder}/bargle" }
    let(:vcenter_ip) { vcenter_config_hash[:vcenter_ip] }
    let(:username) { vcenter_config_hash[:username] }
    let(:password) { vcenter_config_hash[:password] }
    let(:datacenter_name) { vcenter_config_hash[:datacenter_name] }
    let(:datastore_name) { vcenter_config_hash[:datastore_name] }
    let(:datastore_name) { vcenter_config_hash[:datastore_name] }
    let(:logger) { Logger.new(STDERR).tap { |l| l.level = Logger::FATAL } }

    subject(:vm_folder_client) do
      VmFolderClient.new(vcenter_ip, username, password, datacenter_name, datastore_name, logger)
    end

    after(:all) do
      VmFolderClient.new(
        vcenter_config_hash[:vcenter_ip],
        vcenter_config_hash[:username],
        vcenter_config_hash[:password],
        vcenter_config_hash[:datacenter_name],
        vcenter_config_hash[:datastore_name],
        Logger.new(STDERR).tap { |l| l.level = Logger::FATAL },
      ).delete_folder(TEST_PLAYGROUND_FOLDER)
    end

    context 'when it can successfully create folder' do
      after do
        folder = vm_folder_client.datacenter.vmFolder.find(TEST_PLAYGROUND_FOLDER)
        folder.Destroy_Task.wait_for_completion if folder
      end

      it 'creates and deletes the given VM folder' do
        expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).to be_nil

        vm_folder_client.create_folder(nested_folder)
        expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).not_to be_nil

        vm_folder_client.delete_folder(nested_folder)
        expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).to be_nil
      end

      it 'propagates rbvmomi errors' do
        allow(vm_folder_client.datacenter)
          .to receive(:vmFolder)
              .and_raise(RbVmomi::Fault.new('error', nil))

        expect {
          vm_folder_client.delete_folder(nested_folder)
        }.to raise_error(RbVmomi::Fault)

        # unstub to make sure that after block does not fail
        allow(vm_folder_client.datacenter).to receive(:vmFolder).and_call_original
      end

      it 'does not delete parent folders' do
        vm_folder_client.create_folder(nested_folder)
        vm_folder_client.delete_folder(nested_folder)
        expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).to be_nil
        expect(vm_folder_client.datacenter.vmFolder.traverse(parent_folder)).not_to be_nil
        expect(vm_folder_client.datacenter.vmFolder.traverse(TEST_PLAYGROUND_FOLDER)).not_to be_nil
      end

      it 'does not delete sibling folders' do
        vm_folder_client.create_folder(nested_folder)
        nested_sibling = "#{parent_folder}/snake"

        vm_folder_client.create_folder(nested_sibling)
        vm_folder_client.delete_folder(nested_folder)
        expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).to be_nil
        expect(vm_folder_client.datacenter.vmFolder.traverse(nested_sibling)).not_to be_nil
      end

      context 'when there is a folder with slashes in the name ' +
          'that is the same as the nested path' do
        let(:unnested_folder_with_slashes) { nested_folder.gsub('/', '%2f') }

        before do
          # creates a single top level folder whose name is something/with/slashes
          # does not create a nested structure
          # NB: the name of this object when retrieved by RbVmomi will be something%2fwith%2fslashes
          vm_folder_client.datacenter.vmFolder.CreateFolder(name: nested_folder)
        end

        after { vm_folder_client.datacenter.vmFolder.traverse(unnested_folder_with_slashes).Destroy_Task.wait_for_completion }

        it 'does not delete the folder with slashes in its name' do
          expect(vm_folder_client.datacenter.vmFolder.traverse(unnested_folder_with_slashes)).not_to be_nil
          expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).to be_nil

          vm_folder_client.create_folder(nested_folder)
          expect(vm_folder_client.datacenter.vmFolder.traverse(unnested_folder_with_slashes)).not_to be_nil
          expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).not_to be_nil

          vm_folder_client.delete_folder(nested_folder)
          expect(vm_folder_client.datacenter.vmFolder.traverse(unnested_folder_with_slashes)).not_to be_nil
          expect(vm_folder_client.datacenter.vmFolder.traverse(nested_folder)).to be_nil
        end
      end
    end

    context 'when the given VM folder path is invalid' do
      [
        nil,
        '',
        "\\bosh_vms",
        "C:\\\\vms",
        '/bosh_vms',
        'bosh vms',
        'a'*81,
        'colon:name',
        'exciting!/folder',
        'questionable?/folder',
        'sdfsdf&^%$#',
      ].each do |bad_input|
        it "raises an ArgumentError instead of trying to create #{bad_input.inspect}" do
          expect {
            vm_folder_client.create_folder(bad_input)
          }.to raise_error(ArgumentError)
        end

        it "raises an ArgumentError instead of trying to delete #{bad_input.inspect}" do
          expect {
            vm_folder_client.delete_folder(bad_input)
          }.to raise_error(ArgumentError)
        end

        it "raises an ArgumentError instead of checking for existance #{bad_input.inspect}" do
          expect {
            vm_folder_client.folder_exists?(bad_input)
          }.to raise_error(ArgumentError)
        end

        it "raises an ArgumentError instead of looking for VMs #{bad_input.inspect}" do
          expect {
            vm_folder_client.find_vms_by_folder_name(bad_input)
          }.to raise_error(ArgumentError)
        end
      end
    end

    describe '#delete_folder' do
      context 'when folder does not exist' do
        it 'does not raise an error so that action is idempotent' do
          expect {
            vm_folder_client.delete_folder(nested_folder)
          }.not_to raise_error
        end
      end

      context 'when folder exists' do
        context 'when folder is empty' do
          before do
            vm_folder_client.create_folder(TEST_PLAYGROUND_FOLDER)
          end

          it 'deletes the folder' do
            vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
            expect(vm_folder_client.datacenter.vmFolder.traverse(TEST_PLAYGROUND_FOLDER)).to be_nil
          end
        end

        context 'when folder does not contain VMs' do
          before do
            vm_folder_client.create_folder(TEST_PLAYGROUND_FOLDER)
            vm_folder_client.create_folder("#{TEST_PLAYGROUND_FOLDER}/folder1")
            vm_folder_client.create_folder("#{TEST_PLAYGROUND_FOLDER}/folder2")
          end

          it 'deletes the folder and all sub-folders' do
            vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
            expect(vm_folder_client.datacenter.vmFolder.traverse(TEST_PLAYGROUND_FOLDER)).to be_nil
            expect(vm_folder_client.datacenter.vmFolder.traverse("#{TEST_PLAYGROUND_FOLDER}/folder1")).to be_nil
            expect(vm_folder_client.datacenter.vmFolder.traverse("#{TEST_PLAYGROUND_FOLDER}/folder2")).to be_nil
          end
        end

        context 'when folder contains VMs' do
          let(:vim_task) { instance_double('RbVmomi::VIM::Task', wait_for_completion: true) }

          let(:vm_runtime1) { double(:runtime1) }
          let(:vm1) { instance_double('RbVmomi::VIM::VirtualMachine', name: 'vm-name1', runtime: vm_runtime1) }

          let(:vm_runtime2) { double(:runtime2) }
          let(:vm2) { instance_double('RbVmomi::VIM::VirtualMachine', name: 'vm-name2', runtime: vm_runtime2) }

          let(:folder) { instance_double('RbVmomi::VIM::Folder', name: 'vm-folder') }
          let(:sub_folder) { instance_double('RbVmomi::VIM::Folder', name: 'sub-folder') }
          let(:child_entity) { double('childEntity') }

          before do
            vm_folder = instance_double('RbVmomi::VIM::Folder')
            allow(vm_folder).to receive(:traverse).with(TEST_PLAYGROUND_FOLDER) { folder }
            allow(vm_folder_client.datacenter).to receive(:vmFolder).and_return(vm_folder)

            allow(folder).to receive(:childEntity).and_return(child_entity)
          end

          context 'when VMs are in folder' do
            before do
              allow(child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [vm1, vm2] }
              allow(child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [] }
            end

            it 'deletes folder with powered ON VMs' do
              expect(vm_runtime1).to receive(:powerState).once.ordered { 'non-powered-off' }
              expect(vm1).to receive(:PowerOffVM_Task).once.ordered { vim_task }
              expect(vm_runtime2).to receive(:powerState).once.ordered { 'non-powered-off' }
              expect(vm2).to receive(:PowerOffVM_Task).once.ordered { vim_task }
              expect(folder).to receive(:Destroy_Task).once { vim_task }

              vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
            end

            it 'deletes folder with powered OFF VMs' do
              expect(vm_runtime1).to receive(:powerState).once.ordered { 'poweredOff' }
              expect(vm1).not_to receive(:PowerOffVM_Task)
              expect(vm_runtime2).to receive(:powerState).once.ordered { 'poweredOff' }
              expect(vm2).not_to receive(:PowerOffVM_Task)
              expect(folder).to receive(:Destroy_Task).once { vim_task }

              vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
            end
          end

          context 'when VMs are in sub-folders' do
            before do
              allow(child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [vm1] }
              allow(child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [sub_folder] }

              sub_folder_child_entity = double('childEntity')
              allow(sub_folder_child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [vm2] }
              allow(sub_folder_child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [] }
              allow(sub_folder).to receive(:childEntity).and_return(sub_folder_child_entity)
            end

            it 'deletes folder with powered ON VMs' do
              expect(vm_runtime1).to receive(:powerState).once.ordered { 'non-powered-off' }
              expect(vm1).to receive(:PowerOffVM_Task).once.ordered { vim_task }
              expect(vm_runtime2).to receive(:powerState).once.ordered { 'non-powered-off' }
              expect(vm2).to receive(:PowerOffVM_Task).once.ordered { vim_task }
              expect(folder).to receive(:Destroy_Task).once { vim_task }

              vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
            end

            it 'delete folder with powered OFF VMs' do
              expect(vm_runtime1).to receive(:powerState).once.ordered { 'poweredOff' }
              expect(vm1).not_to receive(:PowerOffVM_Task)
              expect(vm_runtime2).to receive(:powerState).once.ordered { 'poweredOff' }
              expect(vm2).not_to receive(:PowerOffVM_Task)
              expect(folder).to receive(:Destroy_Task).once { vim_task }

              vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
            end
          end
        end
      end
    end

    describe '#folder_exists?' do
      context 'when the folder exists' do
        before do
          vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
          vm_folder_client.create_folder(TEST_PLAYGROUND_FOLDER)
        end

        it 'returns true' do
          expect(vm_folder_client.folder_exists?(TEST_PLAYGROUND_FOLDER)).to eq(true)
        end
      end

      context 'when the folder does not exist' do
        before do
          vm_folder_client.delete_folder(TEST_PLAYGROUND_FOLDER)
        end

        it 'returns false' do
          expect(vm_folder_client.folder_exists?(TEST_PLAYGROUND_FOLDER)).to eq(false)
        end
      end
    end

    describe '#find_vms_by_folder_name' do
      context 'when folder is not found' do
        it 'does not raise exception' do
          expect {
            expect(vm_folder_client.find_vms_by_folder_name('does_not_exist_folder')).to eq([])
          }.not_to raise_error
        end
      end

      context 'when folder is found' do
        let(:vm1) { instance_double('RbVmomi::VIM::VirtualMachine') }
        let(:vm2) { instance_double('RbVmomi::VIM::VirtualMachine') }

        let(:folder) { instance_double('RbVmomi::VIM::Folder') }
        let(:sub_folder) { instance_double('RbVmomi::VIM::Folder') }

        let(:child_entity) { double('childEntity') }

        before do
          vm_folder = instance_double('RbVmomi::VIM::Folder')
          allow(vm_folder).to receive(:traverse).with(TEST_PLAYGROUND_FOLDER) { folder }
          allow(vm_folder_client.datacenter).to receive(:vmFolder).and_return(vm_folder)

          allow(folder).to receive(:childEntity).and_return(child_entity)
        end

        context 'when folder has no VMs' do
          before do
            sub_folder_child_entity = double('childEntity')
            allow(sub_folder_child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [] }
            allow(sub_folder_child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [] }
            allow(sub_folder).to receive(:childEntity).and_return(sub_folder_child_entity)

            allow(child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [] }
            allow(folder).to receive(:childEntity).and_return(child_entity)
          end

          it 'returns empty array when folder is empty' do
            allow(child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [] }
            expect(vm_folder_client.find_vms_by_folder_name(TEST_PLAYGROUND_FOLDER)).to eq([])
          end

          it 'returns empty array when folder has only an empty sub-folder' do
            allow(child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [sub_folder] }
            expect(vm_folder_client.find_vms_by_folder_name(TEST_PLAYGROUND_FOLDER)).to eq([])
          end
        end

        context 'when folder has VMs' do
          before do
            sub_folder_child_entity = double('childEntity')
            allow(sub_folder_child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [vm2] }
            allow(sub_folder_child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [] }
            allow(sub_folder).to receive(:childEntity).and_return(sub_folder_child_entity)

            allow(child_entity).to receive(:grep).with(RbVmomi::VIM::VirtualMachine) { [vm1] }
            allow(folder).to receive(:childEntity).and_return(child_entity)
          end

          it 'returns VMs in folder' do
            allow(child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [] }
            expect(vm_folder_client.find_vms_by_folder_name(TEST_PLAYGROUND_FOLDER)).to eq([vm1])
          end

          it 'returns VMs in folder and sub-folder' do
            allow(child_entity).to receive(:grep).with(RbVmomi::VIM::Folder) { [sub_folder] }
            expect(vm_folder_client.find_vms_by_folder_name(TEST_PLAYGROUND_FOLDER)).to eq([vm1, vm2])
          end
        end
      end
    end
  end
end
