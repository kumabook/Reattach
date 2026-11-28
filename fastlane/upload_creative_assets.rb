# Uploads fastlane/app_store_assets/header-<locale>.png to the App Asset Library and places each
# on the product page header and search results of the editable version. fastlane has no support yet
# (fastlane/fastlane#30442). Targets that already have a placement are left alone.
#
#   bundle exec ruby fastlane/upload_creative_assets.rb fastlane/api_key.json fastlane/app_store_assets
require "jwt"; require "json"; require "net/http"; require "openssl"

KEY = JSON.parse(File.read(ARGV[0]))
ASSETS = ARGV[1]
APP_ID = "6757171671"
VERSION = "2.1.0"
UNIVERSAL_SPEC = "c8f4e2b1-7a3d-5c9e-8b6f-2d1a0e9c8b7a"
PLACEMENTS = %w[PRODUCT_PAGE_HEADER_ASSET APP_STORE_SEARCH_RESULTS_ASSET]

def token
  key = OpenSSL::PKey::EC.new(KEY["key"])
  JWT.encode({ iss: KEY["issuer_id"], iat: Time.now.to_i, exp: Time.now.to_i + 1200, aud: "appstoreconnect-v1" },
             key, "ES256", { kid: KEY["key_id"] })
end

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com" + path)
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{token}"
  if body
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)
  end
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  data = res.body.to_s.empty? ? {} : JSON.parse(res.body)
  raise "#{method.upcase} #{path} -> #{res.code} #{data["errors"]&.map { |e| e["detail"] }&.join("; ")}" unless res.is_a?(Net::HTTPSuccess)
  data
end

def upload(operations, bytes)
  operations.each do |op|
    uri = URI(op["url"])
    req = Net::HTTP.const_get(op["method"].capitalize).new(uri)
    op["requestHeaders"].each { |h| req[h["name"]] = h["value"] }
    req.body = bytes.byteslice(op["offset"], op["length"])
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    raise "upload part failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  end
end

library = api(:get, "/v1/apps/#{APP_ID}/assetLibrary")["data"]["id"]
version = api(:get, "/v1/apps/#{APP_ID}/appStoreVersions?filter[versionString]=#{VERSION}&filter[platform]=IOS")["data"].first
puts "version #{VERSION}: #{version["attributes"]["appStoreState"]}"
localizations = api(:get, "/v1/appStoreVersions/#{version["id"]}/appStoreVersionLocalizations")["data"]

{ "ja" => "header-ja.png", "en-US" => "header-en-US.png" }.each do |locale, file|
  loc = localizations.find { |l| l["attributes"]["locale"] == locale } or raise "no #{locale} localization"
  existing = api(:get, "/v1/appStoreVersionLocalizations/#{loc["id"]}/placements")["data"]
    .select { |p| PLACEMENTS.include?(p["attributes"]["placementType"]) }
  unless existing.empty?
    puts "#{locale}: already placed #{existing.map { |p| p["attributes"]["placementType"] }}, skipping"
    next
  end

  bytes = File.binread(File.join(ASSETS, file))
  image = api(:post, "/v1/appAssetLibraryImages", { data: { type: "appAssetLibraryImages",
    attributes: { fileName: file, fileSize: bytes.bytesize, category: "CREATIVE_ASSETS" },
    relationships: { assetLibrary: { data: { type: "appAssetLibraries", id: library } } } } })["data"]
  upload(image["attributes"]["uploadOperations"], bytes)
  image = api(:patch, "/v1/appAssetLibraryImages/#{image["id"]}",
              { data: { type: "appAssetLibraryImages", id: image["id"], attributes: { uploaded: true } } })["data"]
  deadline = Time.now + 300
  until %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW ACCEPTED APPROVED].include?(image["attributes"]["state"])
    raise "#{locale}: image #{image["attributes"]["state"]} #{image["attributes"]["stateDetails"]}" if %w[FAILED REJECTED ARCHIVED].include?(image["attributes"]["state"])
    raise "#{locale}: processing timed out" if Time.now > deadline
    sleep 3
    image = api(:get, "/v1/appAssetLibraryImages/#{image["id"]}")["data"]
  end
  raise "#{locale}: unexpected spec #{image["attributes"]["specId"]}" unless image["attributes"]["specId"] == UNIVERSAL_SPEC
  puts "#{locale}: image #{image["id"]} #{image["attributes"]["state"]}"

  PLACEMENTS.each do |type|
    placement = api(:post, "/v1/appAssetLibraryPlacements", { data: { type: "appAssetLibraryPlacements",
      attributes: { placementType: type, placementGroup: "DEFAULT_PROFILE" },
      relationships: { image: { data: { type: "appAssetLibraryImages", id: image["id"] } },
                       appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc["id"] } } } } })["data"]
    puts "#{locale}: placed #{type} (#{placement["attributes"]["state"]})"
  end
end
