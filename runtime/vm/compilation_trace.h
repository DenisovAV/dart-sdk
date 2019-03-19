// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_COMPILATION_TRACE_H_
#define RUNTIME_VM_COMPILATION_TRACE_H_

#include "platform/assert.h"
#include "vm/object.h"
#include "vm/program_visitor.h"
#include "vm/zone_text_buffer.h"

namespace dart {

class CompilationTraceSaver : public FunctionVisitor {
 public:
  explicit CompilationTraceSaver(Zone* zone);
  void Visit(const Function& function);

  void StealBuffer(uint8_t** buffer, intptr_t* buffer_length) {
    *buffer = reinterpret_cast<uint8_t*>(buf_.buffer());
    *buffer_length = buf_.length();
  }

 private:
  ZoneTextBuffer buf_;
  String& func_name_;
  Class& cls_;
  String& cls_name_;
  Library& lib_;
  String& uri_;
};

class CompilationTraceLoader : public ValueObject {
 public:
  explicit CompilationTraceLoader(Thread* thread);

  RawObject* CompileTrace(uint8_t* buffer, intptr_t buffer_length);

 private:
  RawObject* CompileTriple(const char* uri_cstr,
                           const char* cls_cstr,
                           const char* func_cstr);
  RawObject* CompileFunction(const Function& function);

  Thread* thread_;
  Zone* zone_;
  String& uri_;
  String& class_name_;
  String& function_name_;
  String& function_name2_;
  Library& lib_;
  Class& cls_;
  Function& function_;
  Function& function2_;
  Field& field_;
  Object& error_;
};

class TypeFeedbackSaver : public FunctionVisitor {
 public:
  explicit TypeFeedbackSaver(WriteStream* stream);

  void WriteHeader();
  void SaveClasses();
  void SaveFields();
  void Visit(const Function& function);

 private:
  void WriteClassByName(const Class& cls);
  void WriteString(const String& value);
  void WriteInt(intptr_t value) { stream_->Write(static_cast<int32_t>(value)); }

  WriteStream* const stream_;
  Class& cls_;
  Library& lib_;
  String& str_;
  Array& fields_;
  Field& field_;
  Code& code_;
  Array& call_sites_;
  ICData& call_site_;
};

class TypeFeedbackLoader : public ValueObject {
 public:
  explicit TypeFeedbackLoader(Thread* thread);
  ~TypeFeedbackLoader();

  RawObject* LoadFeedback(ReadStream* stream);

 private:
  RawObject* CheckHeader();
  RawObject* LoadClasses();
  RawObject* LoadFields();
  RawObject* LoadFunction();
  RawFunction* FindFunction(RawFunction::Kind kind, intptr_t token_pos);

  RawClass* ReadClassByName();
  RawString* ReadString();
  intptr_t ReadInt() { return stream_->Read<int32_t>(); }

  Thread* thread_;
  Zone* zone_;
  ReadStream* stream_;
  intptr_t num_cids_;
  intptr_t* cid_map_;
  String& uri_;
  Library& lib_;
  String& cls_name_;
  Class& cls_;
  String& field_name_;
  Array& fields_;
  Field& field_;
  String& func_name_;
  Function& func_;
  Array& call_sites_;
  ICData& call_site_;
  String& target_name_;
  Function& target_;
  Array& args_desc_;
  GrowableObjectArray& functions_to_compile_;
  Object& error_;
};

}  // namespace dart

#endif  // RUNTIME_VM_COMPILATION_TRACE_H_
