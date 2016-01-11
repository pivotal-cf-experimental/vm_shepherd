require 'spec_helper'
require 'vm_shepherd/backport_refinements'

module VmShepherd
  RSpec.describe BackportRefinements do

    describe '.should_refine?' do
      context 'Ruby < 2.3' do
        before { stub_const("RUBY_VERSION", '2.1.0') }

        it 'returns true' do
          expect(BackportRefinements.should_refine?).to eq(true)
        end
      end

      context 'Ruby >= 2.3' do
        before { stub_const("RUBY_VERSION", '2.3.0') }

        it 'returns false' do
          expect(BackportRefinements.should_refine?).to eq(false)
        end
      end
    end

    describe 'Array#dig and Hash#dig' do
      using BackportRefinements

      it 'monkey patches dig for Array' do
        ary = ['a', 'b', 'c', 'd']
        expect(ary.dig(0)).to eq('a')
        expect(ary.dig(1)).to eq('b')
        expect(ary.dig(2)).to eq('c')
        expect(ary.dig(3)).to eq('d')
      end

      it 'monkey patches dig for Hash' do
        hsh = {foo: {bar: :baz}}

        expect(hsh.dig(:foo, :bar)).to eq(:baz)
      end

      it 'monkey patches dig for arbitrarily nested Arrays / Hashes' do
        hsh = {foo: ['nope', {'foo' => 'bar'}]}

        expect(hsh.dig(:foo, 1, 'foo')).to eq('bar')
      end

      it 'returns nil when unable to find a matching object while traversing' do
        hsh = {foo: ['nope', {'foo' => 'bar'}]}

        expect(hsh.dig(0, 'sure', 2, 'not_gonna_happen')).to be_nil
      end
    end
  end
end
