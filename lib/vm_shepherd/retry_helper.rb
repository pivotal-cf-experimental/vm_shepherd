module VmShepherd
  module RetryHelper
    class RetryLimitExceeded < StandardError
    end

    RETRY_LIMIT    = 10
    RETRY_INTERVAL = 60

    def retry_until(retry_limit: RETRY_LIMIT, retry_interval: RETRY_INTERVAL, &block)
      tries             = 0
      condition_reached = false
      loop do
        tries += 1
        raise(RetryLimitExceeded) if tries > retry_limit
        condition_reached = block.call
        break if condition_reached
        sleep retry_interval
      end
      condition_reached
    end
  end
end
