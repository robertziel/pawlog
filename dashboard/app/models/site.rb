# The sites this deployment tracks, from the YAML at PAWLOG_SITES_FILE (see deploy/sites.example.yml).
# Loaded once and validated loudly: a missing file, unknown key or bad url is a boot error.
class Site
  attr_reader :id, :url

  def self.all
    @all ||= begin
      list = YAML.safe_load_file(ENV.fetch("PAWLOG_SITES_FILE")).fetch("sites")
      raise ArgumentError, "sites: must be a non-empty list" unless list.is_a?(Array) && list.any?
      list.map { |h| new(**h.transform_keys(&:to_sym)) }
    end
  end

  def self.find(id)
    all.find { |s| s.id == id } || raise(ActionController::RoutingError, "unknown site #{id}")
  end

  def initialize(id:, url:)
    @id, @url = id.to_s, url.to_s.chomp("/")
    uri = URI(@url)
    raise ArgumentError, "site #{id}: id must match [\\w.-]{1,64}" unless @id.match?(/\A[\w.-]{1,64}\z/)
    raise ArgumentError, "site #{id}: url must be http(s)://host" unless %w[http https].include?(uri.scheme) && uri.host
  end

  def origin
    uri = URI(url)
    "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
  end
end
