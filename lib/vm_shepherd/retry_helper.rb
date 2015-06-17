module VmShepherd
  module RetryHelper
    class RetryLimitExceeded < StandardError
    end

    RETRY_LIMIT = 60
    RETRY_INTERVAL = 10

    def retry_until(retry_limit: RETRY_LIMIT, &block)
      tries = 0
      condition_reached = false
      loop do
        tries += 1
        raise(RetryLimitExceeded) if tries > retry_limit
        condition_reached = block.call
        break if condition_reached
        sleep RETRY_INTERVAL
      end
      condition_reached
    end
  end
end
