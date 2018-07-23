require 'jwt'

module AtlassianJwtAuthentication
  module Filters
    protected

    def on_add_on_installed
      # Add-on key that was installed into the Atlassian Product,
      # as it appears in your add-on's descriptor.
      addon_key = params[:key]

      # Identifying key for the Atlassian product instance that the add-on was installed into.
      # This will never change for a given instance, and is unique across all Atlassian product tenants.
      # This value should be used to key tenant details in your add-on.
      client_key = params[:clientKey]

      # Use this string to sign outgoing JWT tokens and validate incoming JWT tokens.
      shared_secret = params[:sharedSecret]

      # Identifies the category of Atlassian product, e.g. Jira or Confluence.
      product_type = params[:productType]

      # The base URL of the instance
      base_url = params[:baseUrl]
      api_base_url = params[:baseApiUrl] || base_url

      jwt_auth = JwtToken.where(client_key: client_key, addon_key: addon_key).first
      if jwt_auth
        # The add-on was previously installed on this client
        return false unless _verify_jwt(addon_key)
        if jwt_auth.id != current_jwt_auth.id
          # Update request was issued to another plugin
          head(:forbidden)
          return false
        end
      else
        self.current_jwt_auth = JwtToken.new(jwt_token_params)
      end

      current_jwt_auth.addon_key = addon_key
      current_jwt_auth.shared_secret = shared_secret
      current_jwt_auth.product_type = "atlassian:#{product_type}"
      current_jwt_auth.base_url = base_url if current_jwt_auth.respond_to?(:base_url)
      current_jwt_auth.api_base_url = api_base_url if current_jwt_auth.respond_to?(:api_base_url)
      current_jwt_auth.oauth_client_id = params[:oauthClientId] if current_jwt_auth.respond_to?(:oauth_client_id)
      current_jwt_auth.public_key = params[:publicKey] if current_jwt_auth.respond_to?(:public_key)
      current_jwt_auth.payload = params.to_unsafe_h if current_jwt_auth.respond_to?(:payload)

      current_jwt_auth.save!

      # BitBucket sends user details on installation
      [:principal, :user].each do |key|
        if params[key].present?
          user = params[key]
          if user[:username].present? && user[:display_name].present? &&
              user[:uuid].present? && user[:type].present? && user[:type] == 'user'

            jwt_user = current_jwt_auth.jwt_users.where(user_key: user[:uuid]).first
            JwtUser.create(jwt_token_id: current_jwt_auth.id,
                           user_key: user[:uuid],
                           name: user[:username],
                           display_name: user[:display_name]) unless jwt_user
          end
        end
      end

      true
    end

    def on_add_on_uninstalled
      addon_key = params[:key]

      return unless _verify_jwt(addon_key)

      client_key = params[:clientKey]

      return false unless client_key.present?

      auths = JwtToken.where(client_key: client_key, addon_key: addon_key)
      auths.each do |auth|
        auth.destroy
      end

      true
    end

    def verify_jwt(addon_key)
      _verify_jwt(addon_key, true)
    end

    def ensure_license
      unless current_jwt_auth
        raise 'current_jwt_auth missing, add the verify_jwt filter'
      end

      response = rest_api_call(:get, "/rest/atlassian-connect/1/addons/#{current_jwt_auth.addon_key}")
      unless response.success? && response.data
        head(:unauthorized)
        return false
      end

      current_version = Gem::Version.new(response.data['version'])

      if min_licensing_version && current_version > min_licensing_version || !min_licensing_version
        # do we need to check for licensing on this add-on version?
        unless params[:lic] && params[:lic] == 'active'
          head(:unauthorized)
          return false
        end

        unless response.data['state'] == 'ENABLED' &&
            response.data['license'] && response.data['license']['active']
          head(:unauthorized)
          return false
        end
      end

      true
    end

    private

    def _verify_jwt(addon_key, consider_param = false)
      self.current_jwt_auth = nil
      self.current_jwt_user = nil

      jwt = nil

      # The JWT token can be either in the Authorization header
      # or can be sent as a parameter. During the installation
      # handshake we only accept the token coming in the header
      if consider_param
        jwt = params[:jwt] if params[:jwt].present?
      elsif !request.headers['authorization'].present?
        head(:unauthorized)
        return false
      end

      if request.headers['authorization'].present?
        algorithm, jwt = request.headers['authorization'].split(' ')
        jwt = nil unless algorithm == 'JWT'
      end

      jwt_auth, jwt_user, client_token = AtlassianJwtAuthentication::Verify.verify_jwt(addon_key, jwt, request, exclude_qsh_params)

      if !jwt_auth
        head(:unauthorized)
        return false
      end

      self.current_jwt_auth = jwt_auth
      self.current_jwt_user = jwt_user

      response.set_header('x-acpt', client_token)

      true
    end

    def jwt_token_params
      {
          client_key: params.permit(:clientKey)['clientKey'],
          addon_key: params.permit(:key)['key']
      }
    end

    # This can be overwritten in the including controller
    def exclude_qsh_params
      []
    end

    # This can be overwritten in the including controller
    def min_licensing_version
      nil
    end
  end
end
