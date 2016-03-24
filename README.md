# Atlassian JWT Authentication

Atlassian JWT Authentication provides support for handling JWT authentication as required by
 Atlassian when building add-ons: https://developer.atlassian.com/static/connect/docs/latest/concepts/authentication.html

## Installation

### From Git

You can check out the latest source from git:

    git clone https://github.com/MeisterLabs/atlassian-jwt-authentication.git

Or, if you're using Bundler, just add the following to your Gemfile:

    gem 'atlassian-jwt-authentication'

## Usage

This gem relies on the `jwt_tokens` table being present in your database.
The required fields are:

* `addon_key`
* `client_key`
* `shared_secret`
* `product_type`
* `user_key`

Or you can use the provided generator that will create this table for you:

```ruby
bundle exec rails g atlassian_jwt_authentication:create_tables

```

## Requirements

Ruby 2.0+, ActiveRecord 4.1+