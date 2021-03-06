# Copyright (C) Endpoints Server Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;

################################################################################

use src::nginx::t::ApiManager;   # Must be first (sets up import path to the Nginx test module)
use src::nginx::t::HttpServer;
use src::nginx::t::ServiceControl;
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework
use JSON::PP;

################################################################################

# Port assignments
my $NginxPort = ApiManager::pick_port();
my $BackendPort = ApiManager::pick_port();
my $ServiceControlPort = ApiManager::pick_port();
my $CloudTracePort = ApiManager::pick_port();

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(10);

# Save service name in the service configuration protocol buffer file.
my $config = ApiManager::get_bookstore_service_config_allow_unregistered .
    ApiManager::read_test_file('testdata/logs_metrics.pb.txt') . <<"EOF";
producer_project_id: "api-manager-project"
control {
  environment: "http://127.0.0.1:${ServiceControlPort}"
}
EOF
$t->write_file('service.pb.txt', $config);

# Set a very large timer timeout to test trigger flush by max count.
$t->write_file('server_config.pb.txt', <<"EOF");
cloud_tracing_config {
  url_override: "http://127.0.0.1:${CloudTracePort}"
  aggregation_config {
    time_millisec: 1000000
    cache_max_size: 1
  }
  samling_config {
    minimum_qps: 0
  }
}
EOF

$t->write_file_expand('nginx.conf', <<"EOF");
%%TEST_GLOBALS%%
daemon off;
events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server_tokens off;
  server {
    listen 127.0.0.1:${NginxPort};
    server_name localhost;
    location / {
      endpoints {
        api service.pb.txt;
        server_config server_config.pb.txt;
        on;
      }
      proxy_pass http://127.0.0.1:${BackendPort};
    }
  }
}
EOF

my $trace_done = 'trace_done';

$t->run_daemon(\&bookstore, $t, $BackendPort, 'bookstore.log');
$t->run_daemon(\&servicecontrol, $t, $ServiceControlPort, 'servicecontrol.log');
$t->run_daemon(\&cloudtrace, $t, $CloudTracePort, 'cloudtrace.log', $trace_done);

is($t->waitforsocket("127.0.0.1:${BackendPort}"), 1, 'Bookstore socket ready.');
is($t->waitforsocket("127.0.0.1:${ServiceControlPort}"), 1, 'Service control socket ready.');
is($t->waitforsocket("127.0.0.1:${CloudTracePort}"), 1, 'Cloud trace socket ready.');

$t->run();

################################################################################

# These requests should both trigger trace, the second one will cause cache
# to be full and trigger flush.
my $trace_id_0 = "000a5f706abfdb2b6b257826ca503e63";
ApiManager::http($NginxPort, <<"EOF");
GET /shelves?key=this-is-an-api-key HTTP/1.0
Host: localhost
X-Cloud-Trace-Context: ${trace_id_0};o=1

EOF

my $trace_id_1 = "370835b626fd525dfd1b46d34755140d";
ApiManager::http($NginxPort, <<"EOF");
GET /shelves?key=this-is-an-api-key HTTP/1.0
Host: localhost
X-Cloud-Trace-Context: ${trace_id_1};o=1

EOF

is($t->waitforfile("$t->{_testdir}/${trace_done}"), 1, 'Trace body file ready.');

my @requests = ApiManager::read_http_stream($t, 'cloudtrace.log');

# Verify the trace request received.
is(scalar @requests, 1, 'Cloud Trace received 1 request.');
my $trace_request = shift @requests;
is($trace_request->{verb}, 'PATCH', 'Cloud Trace: request is PATCH.');
is($trace_request->{uri}, '/v1/projects/api-manager-project/traces', 'Trace request was called with correct project id in url.');
my $json_obj = decode_json($trace_request->{body});
my $traces = $json_obj->{traces};
is(scalar @$traces, 2, 'Trace request contains two traces.');
is($json_obj->{traces}->[0]->{traceId}, $trace_id_0, 'First Trace ID matches the provided one.');
is($json_obj->{traces}->[1]->{traceId}, $trace_id_1, 'Second Trace ID matches the provided one.');

################################################################################

sub servicecontrol {
  my ($t, $port, $file) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';

  $server->on_sub('POST', '/v1/services/endpoints-test.cloudendpointsapis.com:check', sub {
    my ($headers, $body, $client) = @_;
    print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF
  });

  $server->on_sub('POST', '/v1/services/endpoints-test.cloudendpointsapis.com:report', sub {
    my ($headers, $body, $client) = @_;
    print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF
  });

  $server->run();
}

################################################################################

sub bookstore {
  my ($t, $port, $file) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';

  $server->on_sub('GET', '/shelves', sub {
    my ($headers, $body, $client) = @_;
    print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

Shelves data.
EOF
  });

  $server->run();
}

################################################################################

sub cloudtrace {
  my ($t, $port, $file, $done) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
      or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';

  $server->on_sub('PATCH', '/v1/projects/api-manager-project/traces', sub {
        my ($headers, $body, $client) = @_;
        print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

{}
EOF
        $t->write_file($done, ':trace done');
      });

  $server->run();
}

################################################################################
