// Copyright (C) Endpoints Server Proxy Authors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
// OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
// SUCH DAMAGE.
//
////////////////////////////////////////////////////////////////////////////////
//
#include "src/api_manager/request_handler.h"

#include "google/devtools/cloudtrace/v1/trace.pb.h"
#include "google/protobuf/stubs/logging.h"
#include "src/api_manager/auth/service_account_token.h"
#include "src/api_manager/check_workflow.h"
#include "src/api_manager/utils/marshalling.h"

using ::google::api_manager::utils::Status;
using google::devtools::cloudtrace::v1::Traces;

namespace google {
namespace api_manager {

void RequestHandler::Check(std::function<void(Status status)> continuation) {
  context_->set_check_continuation(continuation);

  // Run the check flow.
  check_workflow_->Run(context_);
}

// Sends a report.
void RequestHandler::Report(std::unique_ptr<Response> response,
                            std::function<void(void)> continuation) {
  if (context_->service_context()->service_control()) {
    service_control::ReportRequestInfo info;
    context_->FillReportRequestInfo(response.get(), &info);

    // Calling service_control Report.
    Status status =
        context_->service_context()->service_control()->Report(info);
    if (!status.ok()) {
      context_->service_context()->env()->LogError(
          "Failed to send report to service control.");
    }
  }

  if (context_->cloud_trace()) {
    SendTraces();
  }

  continuation();
}

std::string RequestHandler::GetBackendAddress() const {
  if (context_->method()) {
    return context_->method()->backend_address();
  } else {
    return std::string();
  }
}

std::string RequestHandler::GetRpcMethodFullName() const {
  if (context_ && context_->method() &&
      !context_->method()->rpc_method_full_name().empty()) {
    return context_->method()->rpc_method_full_name();
  } else {
    return std::string();
  }
}

bool RequestHandler::CanBeTranscoded() const {
  // Verify that all the necessary pieces exist and the method has RPC info
  // configured
  return context_ && context_->service_context() &&
         context_->service_context()->transcoder_factory() &&
         context_->method() &&
         !context_->method()->rpc_method_full_name().empty() &&
         !context_->method()->request_type_url().empty() &&
         !context_->method()->response_type_url().empty();
}

Status RequestHandler::CreateTranscoder(
    ::google::protobuf::io::ZeroCopyInputStream* request_in,
    ::google::protobuf::io::ZeroCopyInputStream* response_in,
    std::unique_ptr<transcoding::Transcoder>* transcoder) const {
  auto status = context_->service_context()->transcoder_factory()->Create(
      *context_->method_call(), request_in, response_in, transcoder);
  return Status::FromProto(status);
}

void RequestHandler::SendTraces() {
  context_->cloud_trace()->EndRootSpan();
  context_->cloud_trace()->SetProjectId(
      context_->service_context()->project_id());

  auto env = context_->service_context()->env();
  std::unique_ptr<HTTPRequest> http_request(
      new HTTPRequest([env](Status status, std::string&& body) {
        env->LogDebug("Trace Response: " + status.ToString() + "\n" + body);
      }));

  std::string url =
      context_->service_context()->cloud_trace_config()->cloud_trace_address() +
      "/v1/projects/" + context_->service_context()->project_id() + "/traces";

  std::string request_body;
  Traces traces;
  traces.mutable_traces()->AddAllocated(
      context_->cloud_trace()->ReleaseTrace());
  ProtoToJson(traces, &request_body, utils::DEFAULT);
  env->LogDebug("Sending request to Cloud Trace.");
  env->LogDebug(request_body);

  http_request->set_url(url)
      .set_method("PATCH")
      .set_auth_token(
          context_->service_context()->service_account_token()->GetAuthToken(
              auth::ServiceAccountToken::JWT_TOKEN_FOR_CLOUD_TRACING))
      .set_header("Content-Type", "application/json")
      .set_body(request_body);

  Status status = env->RunHTTPRequest(std::move(http_request));
  if (!status.ok()) {
    env->LogDebug("Trace Request Failed." + status.ToString());
  }
}

}  // namespace api_manager
}  // namespace google