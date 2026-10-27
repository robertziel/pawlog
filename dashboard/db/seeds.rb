# The single admin, from env. Idempotent; run on every boot.
User.find_or_create_by!(email_address: ENV.fetch("ADMIN_EMAIL")) { |u| u.password = ENV.fetch("ADMIN_PASSWORD") }
