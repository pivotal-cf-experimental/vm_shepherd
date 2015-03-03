require 'vm_shepherd/ova_manager/base'

module VmShepherd
  module OvaManager
    RSpec.describe Base do
      subject(:base) { Base.new(vcenter) }

      let(:vcenter) { { host: 'host', user: 'user', password: 'password' } }
      let(:search_index) { double('searchIndex') }
      let(:connection) { double('RbVmomi::VIM', searchIndex: search_index) }
      let(:datacenter) { FakeDatacenter.new }

      class FakeDatacenter < RbVmomi::VIM::Datacenter
        def initialize
        end
      end

      before { allow(RbVmomi::VIM).to receive(:connect).and_return(connection) }

      def stub_search(find_result)
        allow(search_index).to receive(:FindByInventoryPath).and_return(find_result)
      end

      describe '#find_datacenter' do
        it 'should return datacenter with valid name' do
          stub_search(datacenter)
          expect(base.find_datacenter('valid_datacenter')).to be(datacenter)
        end

        it 'should return nil with invalid name' do
          stub_search(nil)
          expect(base.find_datacenter('does_not_exist')).to be_nil
        end

        it 'should return nil when find returns non-datacenter' do
          stub_search(double)
          expect(base.find_datacenter('non_a_datacenter')).to be_nil
        end
      end

      describe '#connection' do
        it 'should return a connection' do
          conn = base.send(:connection)
          expect(conn).to be(connection)
        end

        it 'should return the same connection on subsequent invocations' do
          conn = base.send(:connection)
          conn_again = base.send(:connection)
          expect(conn).to be(conn_again)
          expect(RbVmomi::VIM).to have_received(:connect).once
        end
      end
    end
  end
end
