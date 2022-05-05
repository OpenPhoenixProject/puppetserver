require 'puppet'
require 'puppet/server'
require 'puppet/server/config'
require 'puppet/server/http_response'
require 'puppet/http/client'
require 'puppet/http/errors'
require 'base64'

require 'java'
java_import com.puppetlabs.http.client.RequestOptions
java_import com.puppetlabs.http.client.ClientOptions
java_import com.puppetlabs.http.client.CompressType
java_import com.puppetlabs.http.client.ResponseBodyType
SyncHttpClient = com.puppetlabs.http.client.Sync

class Puppet::Server::HttpClientError < Puppet::HTTP::HTTPError
  attr_reader :cause

  def initialize(message, cause = nil)
    super(message)
    @cause = cause
  end
end

class Puppet::Server::HttpClient < Puppet::HTTP::Client

  # Store a java HashMap of settings related to the http client
  def self.initialize_settings(settings)
    @settings = settings.select { |k,v|
      ["server_id",
       "metric_registry",
       "ssl_protocols",
       "cipher_suites",
       "http_connect_timeout_milliseconds",
       "http_idle_timeout_milliseconds"].include? k
    }
  end

  def self.settings
    @settings ||= {}
  end

  def initialize(options = {})
    # NOTE: Unlike Puppet's HTTP client implementation, the Java HttpAsyncClient
    # does not support retries in the version we are using, so the `retry_limit`
    # option will be ignored if passed.
    #
    # Similarly, `redirect_limit` is not easily configurable, so we just use the default
    # of 100. The param will be ignored if passed.
  end

  def get(url, headers: {}, params: {}, options: {}, &block)
    include_system_store = options.delete(:include_system_store)
    request_options = create_common_request_options(url, headers, params, options)
    java_response = self.class.client_get(request_options, include_system_store: include_system_store)
    ruby_response = Puppet::Server::HttpResponse.new(java_response, URI(request_options.uri.to_s))
    if block_given?
      yield ruby_response
    end

    ruby_response
  end

  def post(url, body, headers: {}, params: {}, options: {}, &block)
    include_system_store = options.delete(:include_system_store)
    request_options = create_common_request_options(url, headers, params, options)
    request_options.set_body(body)

    compress = options[:compress]
    if compress
      compress_as_sym = compress.to_sym
      if compress_as_sym == :gzip
        request_options.set_compress_request_body(CompressType::GZIP)
      else
        raise ArgumentError, "Unsupported compression specified for request: #{compress}"
      end
    end

    java_response = self.class.client_post(request_options, include_system_store: include_system_store)
    ruby_response = Puppet::Server::HttpResponse.new(java_response, URI(request_options.uri.to_s))
    if block_given?
      yield ruby_response
    end

    ruby_response
  end

  def create_common_request_options(url, headers, params, options)
    if !url.is_a?(URI)
      raise ArgumentError, "URL must be provided as a URI object."
    end

    # If credentials were supplied for HTTP basic auth, add them into the headers.
    # This is based on the code in lib/puppet/reports/http.rb.
    credentials = options[:basic_auth]
    if credentials
      # http://en.wikipedia.org/wiki/Basic_access_authentication#Client_side
      encoded = Base64.strict_encode64("#{credentials[:user]}:#{credentials[:password]}")
      authorization = "Basic #{encoded}"

      if headers["Authorization"] && headers["Authorization"] != authorization
        raise "Existing 'Authorization' header conflicts with supplied HTTP basic auth credentials."
      end

      headers["Authorization"] = authorization
    end

    # Ensure multiple requests are not made on the same connection
    headers["Connection"] = "close"

    # TODO: this is using the same value as the agent would use.
    # It would be better to have it include puppetserver's version
    # instead of the puppet version, and include that we're running
    # in JRuby more explicitly.
    # TODO: Add a X-Puppetserver-Version header to match the one
    # the agent sends, but with our version instead.
    headers["User-Agent"] ||= Puppet[:http_user_agent]

    url = encode_query(url, params)

    # Java will reparse the string into its own URI object
    request_options = RequestOptions.new(url.to_s)
    if options[:metric_id]
      request_options.set_metric_id(options[:metric_id])
    end
    request_options.set_headers(headers)
    request_options.set_as(ResponseBodyType::TEXT)
  end

  def self.terminate
    unless @client.nil?
      @client.close
      @client = nil
    end
  end

  private

  def self.configure_timeouts(client_options)
    settings = self.settings

    if settings.has_key?("http_connect_timeout_milliseconds")
      client_options.set_connect_timeout_milliseconds(settings["http_connect_timeout_milliseconds"])
    end

    if settings.has_key?("http_idle_timeout_milliseconds")
      client_options.set_socket_timeout_milliseconds(settings["http_idle_timeout_milliseconds"])
    end
  end

  def self.configure_ssl(client_options, include_system_store:)
    if include_system_store
      client_options.set_ssl_context(Puppet::Server::Config.puppet_and_system_ssl_context)
    else
      client_options.set_ssl_context(Puppet::Server::Config.puppet_only_ssl_context)
    end

    settings = self.settings

    if settings.has_key?("ssl_protocols")
      client_options.set_ssl_protocols(settings["ssl_protocols"])
    end
    if settings.has_key?("cipher_suites")
      client_options.set_ssl_cipher_suites(settings["cipher_suites"])
    end
  end

  def self.configure_metrics(client_options)
    settings = self.settings
    if settings.has_key?("metric_registry")
      client_options.set_metric_registry(settings["metric_registry"])
    end
    if settings.has_key?("server_id")
      client_options.set_server_id(settings["server_id"])
    end
  end

  def self.create_client_options(include_system_store:)
    client_options = ClientOptions.new
    self.configure_timeouts(client_options)
    self.configure_ssl(client_options, include_system_store: include_system_store)
    self.configure_metrics(client_options)
    client_options.set_enable_url_metrics(false)
    client_options
  end

  def self.create_client(include_system_store:)
    client_options = create_client_options(include_system_store: include_system_store)
    SyncHttpClient.createClient(client_options)
  end

  def self.client
    @client ||= create_client(include_system_store: false)
  end

  def self.client_with_system_certs
    @client_with_system_certs ||= create_client(include_system_store: true)
  end

  def self.choose_client(include_system_store:)
    include_system_store ? self.client_with_system_certs : self.client
  end

  def self.client_post(request_options, include_system_store: false)
    self.choose_client(include_system_store: include_system_store).post(request_options)
  rescue Java::ComPuppetlabsHttpClient::HttpClientException => e
    raise Puppet::Server::HttpClientError.new(e.message, e)
  end

  def self.client_get(request_options, include_system_store: false)
    self.choose_client(include_system_store: include_system_store).get(request_options)
  rescue Java::ComPuppetlabsHttpClient::HttpClientException => e
    raise Puppet::Server::HttpClientError.new(e.message, e)
  end

  def create_session
    raise NotImplementedError
  end

  def connect(uri, options: {}, &block)
    raise NotImplementedError
  end

  def head(url, headers: {}, params: {}, options: {})
    raise NotImplementedError
  end

  def put(url, headers: {}, params: {}, options: {})
    raise NotImplementedError
  end

  def delete(url, headers: {}, params: {}, options: {})
    raise NotImplementedError
  end
end
