use inc::Module::Install;

# Define metadata
name         'ssession';
author       'Joshua Thayer <joshuamilesthayer@gmail.com>';
license      'perl';
perl_version '5.005';
all_from     'lib/Plack/Middleware/StreamingSession.pm';

# Specific dependencies

auto_install;

WriteAll;
