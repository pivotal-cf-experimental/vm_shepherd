require 'vm_shepherd/retry_helper'

module VmShepherd
  RSpec.describe RetryHelper do
    subject(:retry_helper) { TestRetryHelper.new }

    class TestRetryHelper
      include RetryHelper
    end

    before do
      allow(retry_helper).to receive(:sleep) # speed up retry logic
    end

    it 'calls the given block 60 times by default' do
      sixty_times = [true] + [false] * 59
      expect {
        retry_helper.retry_until { sixty_times.pop }
      }.not_to raise_error

      sixty_one_times = [true] + [false] * 60
      expect {
        retry_helper.retry_until { sixty_one_times.pop }
      }.to raise_error(RetryHelper::RetryLimitExceeded)
    end

    it 'throws an error if the block never returns true' do
      expect {
        retry_helper.retry_until { false }
      }.to raise_error(RetryHelper::RetryLimitExceeded)
    end

    it 'returns early if the block returns a truthy value' do
      counter = 0
      retry_helper.retry_until do
        counter += 1
        counter == 6
      end
      expect(counter).to eq(6)
    end

    it 'returns the value of the block' do
      expect(retry_helper.retry_until { 'retrying' }).to eq('retrying')
    end

    it 'calls the given block the given number of times' do
      forty_two_times = [true] + [false] * 41
      expect {
        retry_helper.retry_until(retry_limit: 42) { forty_two_times.pop }
      }.not_to raise_error

      forty_three_times = [true] + [false] * 42
      expect {
        retry_helper.retry_until(retry_limit: 42) { forty_three_times.pop }
      }.to raise_error(RetryHelper::RetryLimitExceeded)
    end
  end
end
