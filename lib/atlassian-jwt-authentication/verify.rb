require 'jwt'

module AtlassianJwtAuthentication
  class JWTVerification
    attr_accessor :addon_key, :jwt, :request, :exclude_qsh_params, :logger

    def initialize(addon_key, jwt, request, &block)
      self.addon_key = addon_key
      self.jwt = jwt
      self.request = request

      self.exclude_qsh_params = []
      self.logger = nil

      yield self if block_given?
    end

    def verify
      unless jwt.present? && addon_key.present?
        return false
      end

      # First decode the token without signature & claims verification
      begin
        decoded = JWT.decode(jwt, nil, false, { verify_expiration: AtlassianJwtAuthentication.verify_jwt_expiration, algorithm: 'HS256' })
      rescue => e
        log(:error, "Could not decode JWT: #{e.to_s} \n #{e.backtrace.join("\n")}")
        return false
      end

      # Extract the data
      data = decoded[0]
      encoding_data = decoded[1]

      # Find a matching JWT token in the DB
      jwt_auth = JwtToken.where(
          client_key: data['iss'],
          addon_key: addon_key
      ).first

      unless jwt_auth
        log(:error, "Could not find jwt_token for client_key #{data['iss']} and addon_key #{addon_key}")
        return false
      end

      # Discard the tokens without verification
      if encoding_data['alg'] == 'none'
        log(:error, "The JWT checking algorithm was set to none for client_key #{data['iss']} and addon_key #{addon_key}")
        return false
      end

      # Decode the token again, this time with signature & claims verification
      options = JWT::DefaultOptions::DEFAULT_OPTIONS.merge(verify_expiration: AtlassianJwtAuthentication.verify_jwt_expiration)
      decoder = JWT::Decode.new(jwt, jwt_auth.shared_secret, true, options)
      payload, header = decoder.decode_segments

      unless header && payload
        log(:error, "Error decoding JWT segments - no header and payload for client_key #{data['iss']} and addon_key #{addon_key}")
        return false
      end

      if data['qsh']
        # Verify the query has not been tampered by Creating a Query Hash and
        # comparing it against the qsh claim on the verified token
        if jwt_auth.base_url.present? && request.url.include?(jwt_auth.base_url)
          path = request.url.gsub(jwt_auth.base_url, '')
        else
          path = request.path.gsub(AtlassianJwtAuthentication::context_path, '')
        end
        path = '/' if path.empty?

        qsh_parameters = request.query_parameters.except(:jwt)

        exclude_qsh_params.each { |param_name| qsh_parameters = qsh_parameters.except(param_name) }

        qsh = request.method.upcase + '&' + path + '&' +
            qsh_parameters.
                sort.
                map{ |param_pair| encode_param(param_pair) }.
                join('&')

        qsh = Digest::SHA256.hexdigest(qsh)

        unless data['qsh'] == qsh
          log(:error, "QSH mismatch for client_key #{data['iss']} and addon_key #{addon_key}")
          return false
        end
      end

      context = data['context']

      # In the case of Confluence and Jira we receive user information inside the JWT token
      if data['context'] && data['context']['user']
        account_id = data['context']['user']['accountId']
      else
        account_id = data['sub']
      end

      [jwt_auth, account_id, context]
    end

    private

    def encode_param(param_pair)
      key, value = param_pair

      if value.respond_to?(:to_query)
        value.to_query(key)
      else
        ERB::Util.url_encode(key) + '=' + ERB::Util.url_encode(value)
      end
    end

    def log(level, message)
      return if logger.nil?

      logger.send(level.to_sym, message)
    end
  end
end