require 'sensu/transport/base'
require 'aws-sdk'

module Sensu
  module Transport
    class SNSSQS < Sensu::Transport::Base
      attr_accessor :logger

      STRING_STR     = "String".freeze
      KEEPALIVES_STR = "keepalives".freeze
      PIPE_STR       = "pipe".freeze
      TYPE_STR       = "type".freeze

      def initialize
        @connected = false
        @subscribing = false
      end

      def connected?; @connected; end

      def connect(settings)
        @settings = settings
        @connected = true
        @results_callback = proc {}
        @keepalives_callback = proc {}
        @sqs = Aws::SQS::Client.new(region: @settings[:region])
        @sns = Aws::SNS::Client.new(region: @settings[:region])
      end

      # subscribe will begin "subscribing" to the consuming sqs queue.
      #
      # What this really means is that we will start polling for
      # messages from the SQS queue, and, depending on the message
      # type, it will call the appropriate callback.
      #
      # This assumes that the SQS Queue is consuming "Raw" messages
      # from SNS.
      #
      # "subscribing" means that the "callback" parameter will be
      # called when there is a message for you to consume.
      #
      # "funnel" and "type" parameters are completely ignored.
      def subscribe(type, pipe, funnel = nil, options = {}, &callback)
        self.logger.info("subscribing to type=#{type}, pipe=#{pipe}, funnel=#{funnel}")

        if pipe == KEEPALIVES_STR
          @keepalives_callback = callback
        else
          @results_callback = callback
        end

        unless @subscribing
          do_all_the_time {
            EM::Iterator.new(receive_messages, 10).each do |msg, iter|
              if msg.message_attributes[PIPE_STR].string_value == KEEPALIVES_STR
                @keepalives_callback.call(msg, msg.body)
              else
                @results_callback.call(msg, msg.body)
              end
              iter.next
            end
          }
          @subscribing = true
        end
      end

      # acknowledge will delete the given message from the SQS queue.
      def acknowledge(info, &callback)
        EM.defer {
          @sqs.delete_message(
            queue_url: @settings[:consuming_sqs_queue_url],
            receipt_handle: info.receipt_handle,
          )
          callback.call(info) if callback
        }
      end

      # publish publishes a message to the SNS topic.
      #
      # The type, pipe, and options are transformed into SNS message
      # attributes and included with the message.
      def publish(type, pipe, message, options = {}, &callback)
        attributes = {
          TYPE_STR => str_attr(type),
          PIPE_STR => str_attr(pipe)
        }
        options.each do |k, v|
          attributes[k.to_s] = str_attr(v.to_s)
        end
        EM.defer { send_message(message, attributes, &callback) }
      end

      private

      def str_attr(str)
        { :data_type => STRING_STR, :string_value => str }
      end

      def do_all_the_time(&blk)
        callback = proc {
          do_all_the_time(&blk)
        }
        EM.defer(blk, callback)
      end

      def send_message(msg, attributes, &callback)
        resp = @sns.publish(
          target_arn: @settings[:publishing_sns_topic_arn],
          message: msg,
          message_attributes: attributes
        )
        callback.call({ :response => resp }) if callback
      end

      PIPE_ARR = [PIPE_STR]

      # receive_messages returns an array of SQS messages
      # for the consuming queue
      def receive_messages
        begin
          resp = @sqs.receive_message(
            message_attribute_names: PIPE_ARR,
            queue_url: @settings[:consuming_sqs_queue_url],
            wait_time_seconds: @settings[:wait_time_seconds],
            max_number_of_messages: @settings[:max_number_of_messages],
          )
          resp.messages
        rescue Aws::SQS::Errors::ServiceError => e
          self.logger.info(e)
        end
      end
    end
  end
end
