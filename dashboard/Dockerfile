FROM ruby:3.4-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libyaml-dev git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
ENV RAILS_ENV=production RAILS_LOG_TO_STDOUT=1
EXPOSE 3000
# assets compile at start because boot needs the runtime env (ClickHouse, sites); seeds = the admin user
CMD ["sh", "-c", "bin/rails assets:precompile >/dev/null && bin/rails db:prepare && bin/rails db:seed && exec bin/rails server -b 0.0.0.0 -p 3000"]
