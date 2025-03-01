/*
 * Copyright 2022 The Kubernetes Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import React from "react"
import { PassThrough } from "stream"
import { Loading } from "@kui-shell/plugin-client-common"
import { Arguments, Job, isResizable } from "@kui-shell/core"

import Terminal from "./Terminal"

/**
 * This is our impl of the `watch` property that our Terminal
 * component needs, in order to support live updates.
 */
function watch(stream: PassThrough, job: Job) {
  return {
    on: stream.on.bind(stream), // data from pty to terminal
    onInput: job.write.bind(job), // user input from terminal to pty
    unwatch: job.abort.bind(job), // unmount, abort pty job
    onResize: isResizable(job) ? job.resize.bind(job) : undefined,
  }
}

export type Props = {
  cmdline: string
  env: Record<string, string>
  tab: Arguments["tab"]
  repl: Arguments["REPL"]
}

type State = {
  startCount?: number
  job?: Job
  watch?: () => ReturnType<typeof watch>
  catastrophicError?: unknown
}

/**
 * A wrapper around <Terminal/> that handles pty exits. It restarts
 * tne pty and recreates the terminal if this happens.
 */
export default class RestartableTerminal extends React.PureComponent<Props, State> {
  private mounted = false

  private async initPty() {
    if (!this.mounted) {
      return
    }

    try {
      // we need this to wire the pty output through to the Terminal
      // component, which expects something stream-like
      const passthrough = new PassThrough()

      await this.props.repl.qexec(this.props.cmdline, undefined, undefined, {
        tab: this.props.tab,
        env: this.props.env,
        quiet: true, // strange i know, but this forces PTY execution
        onExit: () => {
          if (this.mounted) {
            // restart, if still mounted
            this.initPty()
          }
        },
        onInit: () => (_) => {
          // hooks pty output to our passthrough stream
          passthrough.write(_)
        },
        onReady: (job) => {
          if (this.mounted) {
            this.setState((curState) => ({
              job,
              watch: () => watch(passthrough, job),
              startCount: !curState || curState.startCount === undefined ? 0 : curState.startCount + 1,
            }))
          }
        },
      })
    } catch (err) {
      console.error("Error in RestartableTerminal", err)
      // this.setState({ catastrophicError: err })
    }
  }

  public componentDidMount() {
    this.mounted = true
    this.initPty()
  }

  public componentWillUnmount() {
    this.mounted = false
    this.state?.job?.abort()
  }

  public render() {
    if (!this.state) {
      return <Loading />
    }

    const { watch, catastrophicError } = this.state

    if (catastrophicError) {
      return "Internal Error"
    } else if (!watch) {
      return <Loading />
    } else {
      // force a new Terminal every restart
      const key = !this.state || !this.state.startCount ? 0 : this.state.startCount

      return (
        <div
          className="kui--inverted-color-context flex-fill flex-layout flex-align-stretch"
          style={{ backgroundColor: "var(--color-sidecar-background-02)" }}
        >
          <Terminal watch={watch} key={key} />
        </div>
      )
    }
  }
}
