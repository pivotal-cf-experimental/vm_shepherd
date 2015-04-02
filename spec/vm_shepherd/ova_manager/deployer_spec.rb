require 'tempfile'
require 'vm_shepherd/ova_manager/deployer'

module VmShepherd
  module OvaManager
    RSpec.describe Deployer do
      let(:connection) { instance_double(RbVmomi::VIM) }
      let(:cluster) { double('cluster', resourcePool: cluster_resource_pool) }
      let(:cluster_resource_pool) { double(:cluster_resource_pool, resourcePool: [a_resource_pool, another_resource_pool]) }

      let(:a_resource_pool) { double('resource_pool', name: 'resource_pool_name') }
      let(:another_resource_pool) { double('another_resource_pool', name: 'another_resource_pool_name') }

      let(:target_folder) { double('target_folder') }
      let(:datastore) { double('datastore') }
      let(:network) { double('network', name: 'network') }

      let(:search_index) { double('searchIndex') }
      let(:datacenter) { instance_double(RbVmomi::VIM::Datacenter, network: [network]) }

      let(:cached_ova_deployer) {
        double('CachedOvaDeployer', upload_ovf_as_template: template, linked_clone: linked_clone)
      }
      let(:template) { double('template', name: 'template name') }
      let(:ova_path) { File.join(SPEC_ROOT, 'fixtures', 'ova_manager', 'foo.ova') }
      let(:linked_clone) { double('linked clone', guest_ip: '1.1.1.1') }
      let(:host) { 'FAKE_HOST' }
      let(:username) { 'FAKE_USERNAME' }
      let(:password) { 'FAKE_PASSWORD' }
      let(:datacenter_name) { 'FAKE_DATACENTER' }

      subject(:deployer) { Deployer.new(host, username, password, datacenter_name, location) }

      before do
        allow(deployer).to receive(:system).with(/cd .* && tar xfv .*/).and_call_original
        allow(deployer).to receive(:system).with(/nc -z -w 5 .* 443/).and_return(false)

        allow(datacenter).to receive(:find_compute_resource).with('cluster').and_return(cluster)

        allow(datacenter).to receive(:find_datastore).with('datastore').and_return(datastore)

        allow(linked_clone).to receive_message_chain(:ReconfigVM_Task, :wait_for_completion)
        allow(linked_clone).to receive_message_chain(:PowerOnVM_Task, :wait_for_completion)

        allow(RbVmomi::VIM).to receive(:connect).with({
              host: host,
              user: username,
              password: password,
              ssl: true,
              insecure: true
            }).and_return(connection)

        allow(connection).to receive(:searchIndex).and_return(search_index)
        allow(search_index).to receive(:FindByInventoryPath).and_return(datacenter)
        allow(datacenter).to receive(:is_a?).with(RbVmomi::VIM::Datacenter).and_return(true)

        allow(datacenter).to receive_message_chain(:vmFolder, :traverse).
            with('target_folder', RbVmomi::VIM::Folder, true).and_return(target_folder)
        allow(datacenter).to receive(:networkFolder).and_return(
            double(:networkFolder).tap do |network_folder|
              allow(network_folder).to receive(:traverse).with('network').and_return(network)
            end
          )
      end

      describe '#deploy' do
        context 'resource pool is a parameter' do
          let(:location) do
            {
              connection: connection,
              network: 'network',
              cluster: 'cluster',
              folder: 'target_folder',
              datastore: 'datastore',
              datacenter: 'datacenter',
              resource_pool: resource_pool_name
            }
          end

          context 'resource pool can be found' do
            let(:resource_pool_name) { a_resource_pool.name }

            it 'uses VsphereClient::CachedOvfDeployer to deploy an OVA within a resource pool' do
              expect(VsphereClients::CachedOvfDeployer).to receive(:new).with(
                  connection,
                  network,
                  cluster,
                  a_resource_pool,
                  target_folder,
                  target_folder,
                  datastore
                ).and_return(cached_ova_deployer)

              deployer.deploy('foo', ova_path, {ip: '1.1.1.1'})
            end
          end

          context 'resource pool cannot be found' do
            let(:resource_pool_name) { 'i am no body' }

            it 'uses VsphereClient::CachedOvfDeployer to deploy an OVA within a resource pool' do
              expect {
                deployer.deploy('foo', ova_path, {ip: '1.1.1.1'})
              }.to raise_error(/Failed to find resource pool '#{resource_pool_name}'/)
            end
          end
        end

        context 'when there is no resource pool in location' do
          let(:location) do
            {
              connection: connection,
              network: 'network',
              cluster: 'cluster',
              folder: 'target_folder',
              datastore: 'datastore',
              datacenter: 'datacenter',
            }
          end

          it 'uses the cluster resource pool' do
            expect(VsphereClients::CachedOvfDeployer).to receive(:new).with(
                connection,
                network,
                cluster,
                cluster_resource_pool,
                target_folder,
                target_folder,
                datastore
              ).and_return(cached_ova_deployer)

            deployer.deploy('foo', ova_path, {ip: '1.1.1.1'})
          end
        end
      end

      describe '#find_datacenter' do
        let(:location) do
          {
            connection: connection,
            network: 'network',
            cluster: 'cluster',
            folder: 'target_folder',
            datastore: 'datastore',
            datacenter: 'datacenter',
          }
        end

        it 'should return datacenter with valid name' do
          expect(deployer.find_datacenter('valid_datacenter')).to be(datacenter)
        end

        it 'should return nil with invalid name' do
          allow(search_index).to receive(:FindByInventoryPath).and_return(nil)

          expect(deployer.find_datacenter('does_not_exist')).to be_nil
        end

        it 'should return nil when find returns non-datacenter' do
          allow(search_index).to receive(:FindByInventoryPath).and_return(double)

          expect(deployer.find_datacenter('non_a_datacenter')).to be_nil
        end
      end

      describe '#connection' do
        let(:location) do
          {
            connection: connection,
            network: 'network',
            cluster: 'cluster',
            folder: 'target_folder',
            datastore: 'datastore',
            datacenter: 'datacenter',
          }
        end

        it 'should return a connection' do
          conn = deployer.send(:connection)
          expect(conn).to be(connection)
        end

        it 'should return the same connection on subsequent invocations' do
          conn = deployer.send(:connection)
          conn_again = deployer.send(:connection)
          expect(conn).to be(conn_again)
          expect(RbVmomi::VIM).to have_received(:connect).once
        end
      end
    end
  end
end
