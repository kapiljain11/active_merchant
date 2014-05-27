module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class AdyenGateway < Gateway
      self.test_url = 'https://pal-test.adyen.com/pal/adapter/httppost'
      self.live_url = 'https://pal-live.adyen.com/pal/adapter/httppost'

      self.supported_countries = ['US']
      self.default_currency = 'EUR'
      self.money_format = :cents
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :diners_club, :jcb, :dankort, :maestro]

      self.homepage_url = 'https://www.adyen.com/'
      self.display_name = 'Adyen'

      def initialize(options = {})
        requires!(options, :company, :merchant, :password)
        super
      end

      def purchase(money, creditcard, options = {})
        requires!(options, :order_id)

        MultiResponse.run do |r|
          r.process { authorize(money, creditcard, options) }
          r.process { capture(money, r.authorization, options) }
        end
      end

      def authorize(money, creditcard, options = {})
        requires!(options, :order_id)

        post = {}
        post[:paymentRequest] = payment_request(money, options)
        post[:paymentRequest][:amount] = amount_hash(money, options[:currency])
        post[:paymentRequest][:card] = credit_card_hash(creditcard)

        if address = (options[:billing_address] || options[:address])
          post[:paymentRequest][:billingAddress] = address_hash(address)
        end

        if options[:shipping_address]
          post[:paymentRequest][:deliveryAddress] = address_hash(options[:shipping_address])
        end

        commit('Payment.authorise', post)
      end

      def capture(money, authorization, options = {})
        requires!(options, :order_id)

        post = {}
        post[:modificationRequest] = modification_request(authorization, options)
        post[:modificationRequest][:modificationAmount] = amount_hash(money, options[:currency])
        
        commit('Payment.capture', post)
      end

      def refund(money, authorization, options = {})
        requires!(options, :order_id)

        post = {}
        post[:modificationRequest] = modification_request(authorization, options)
        post[:modificationRequest][:modificationAmount] = amount_hash(money, options[:currency])
        
        commit('Payment.refund', post)
      end

      def void(identification, options = {})
        requires!(options, :order_id)

        post = {}
        post[:modificationRequest] = modification_request(identification, options)

        commit('Payment.cancel', post)
      end

      private

      def commit(action, post)
        request = post_data(flatten_hash(post.merge(:action => action)))
        raw_response = ssl_post(url, request, headers)

        response = Hash[
          parse_response(raw_response).map do |key, val|
            [key.split('.').last.to_sym, val]
          end
        ]

        Response.new(
          success_from(response),
          message_from(response),
          response,
          test: test?,
          authorization: response[:pspReference]
        )

      rescue ResponseError => e
        if e.response.code == '401'
          return Response.new(false, 'Invalid credentials.', {}, :test => test?)
        else
          return Response.new(false, e.response.body, {}, :test => test?)
        end
      end

      def flatten_hash(hash, keys = nil)
        flat_hash = {}
        hash.each_pair do |key, val|
          conc_key = keys.nil? ? key : "#{keys}.#{key}"
          if val.is_a?(Hash)
            flat_hash.merge!(flatten_hash(val, conc_key))
          else
            flat_hash[conc_key.to_sym] = val
          end
        end
        flat_hash
      end

      def headers
        {
          'Authorization' => 'Basic ' + Base64.encode64("ws@Company.#{@options[:company]}:#{@options[:password]}").strip
        }
      end

      def parse_response(response)
        Hash[
          response.split('&').map do |x|
            key, val = x.split('=', 2)
            [key, CGI.unescape(val)]
          end
        ]
      end

      def post_data(data)
        data.map do |key, val|
          "#{key}=#{CGI.escape(val.to_s)}"
        end.reduce do |x, y|
          "#{x}&#{y}"
        end
      end

      def message_from(response)
        return response[:resultCode] if response.has_key?(:resultCode) # Payment request
        return response[:response] if response[:response] # Modification request
      end

      def success_from(response)
        return true if response.has_key?(:authCode)
        return true if response[:response] == '[capture-received]'
        return true if response[:response] == '[cancel-received]'
        return true if response[:response] == '[refund-received]'
        return false
      end

      def url
        test? ? self.test_url : self.live_url
      end

      def address_hash(address)
        {
          :city              => address[:city],
          :street            => address[:address1],
          :houseNumberOrName => address[:address2],
          :postalCode        => address[:zip],
          :stateOrProvince   => address[:state],
          :country           => address[:country]
        }
      end

      def amount_hash(money, currency)
        {
          :currency => (currency || currency(money)),
          :value    => money
        }
      end

      def credit_card_hash(creditcard)
        {
          :cvc         => creditcard.verification_value,
          :expiryMonth => format(creditcard.month, :two_digits),
          :expiryYear  => format(creditcard.year, :four_digits),
          :holderName  => creditcard.name,
          :number      => creditcard.number
        }
      end

      def modification_request(reference, options)
        {
          :merchantAccount    => @options[:merchant],
          :originalReference  => reference
        }.keep_if { |_, v| v }
      end

      def payment_request(money, options)
        {
          :merchantAccount  => @options[:merchant],
          :reference        => options[:order_id],
          :shopperEmail     => options[:email],
          :shopperIP        => options[:ip],
          :shopperReference => options[:customer]
        }.keep_if { |_, v| v }
      end
    end
  end
end
