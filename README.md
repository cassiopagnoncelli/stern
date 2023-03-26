# Stern
Double-entry ledger Rails engine.

## Usage
Plug into your existing app and attach it to (preferably brand new) database.

## Installation
Add this line to your application's Gemfile:

```ruby
gem "stern"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install stern
```

## Contributing
Contribution directions go here.

## Parameters.

This engine was created with

```
rails plugin new stern \
  --mountable \
  --database postgresql \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-action-storage \
  --skip-action-cable \
  --skip-hotwire --skip-sprockets --skip-javascript --skip-turbolinks \
  --skip-test --skip-system-test \
  --skip-gemfile-entry \
  --css=tailwind \
  --dummy_path=spec/dummy
```

## License
You need written authorization from the author for commercial usage.
