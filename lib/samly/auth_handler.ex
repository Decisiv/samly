defmodule Samly.AuthHandler do
  @moduledoc false

  require Logger
  import Plug.Conn
  import Samly.RouterUtil, only: [ensure_sp_uris_set: 2, send_saml_request: 5, redirect: 3]

  alias Plug.Conn
  alias Samly.{Assertion, IdpData, Helper, State, Subject}

  @sso_init_resp_template """
  <body onload=\"document.forms[0].submit()\">
    <noscript>
      <p><strong>Note:</strong>
        Since your browser does not support JavaScript, you must press
        the button below once to proceed.
      </p>
    </noscript>
    <form method=\"post\" action=\"<%= action %>\">
      <%= if target_url do %>
      <input type=\"hidden\" name=\"target_url\" value=\"<%= target_url %>\" />
      <% end %>
      <input type=\"hidden\" name=\"_csrf_token\" value=\"<%= csrf_token %>\" />
      <noscript><input type=\"submit\" value=\"Submit\" /></noscript>
    </form>
  </body>
  """

  def initiate_sso_req(%Conn{params: %Conn.Unfetched{}} = conn) do
    conn
    |> fetch_query_params()
    |> initiate_sso_req()
  end

  def initiate_sso_req(conn) do
    import Plug.CSRFProtection, only: [get_csrf_token: 0]

    target_url =
      case conn.params["target_url"] do
        nil -> nil
        url -> URI.decode_www_form(url)
      end

    opts = [
      action: conn.request_path,
      target_url: target_url,
      csrf_token: get_csrf_token()
    ]

    conn
    |> put_resp_header("content-type", "text/html")
    |> send_resp(200, EEx.eval_string(@sso_init_resp_template, opts))
  end

  def send_signin_req(conn, state \\ Application.get_env(:samly, :state_provider, State.Ets)) do
    %IdpData{id: idp_id} = idp = conn.private[:samly_idp]
    %IdpData{esaml_idp_rec: idp_rec, esaml_sp_rec: sp_rec} = idp
    sp = ensure_sp_uris_set(sp_rec, conn)

    target_url = (conn.params["target_url"] || "/") |> URI.decode_www_form()

    case state.get(conn, "samly_assertion") do
      {_ ,%Assertion{idp_id: ^idp_id}}->
        conn
        |> redirect(302, target_url)

      _ ->
        relay_state = State.gen_id()
        {idp_signin_url, req_xml_frag} = Helper.gen_idp_signin_req(sp, idp_rec)

        conn
        |> configure_session(renew: true)
        |> put_session("relay_state", relay_state)
        |> put_session("idp_id", idp_id)
        |> put_session("target_url", target_url)
        |> send_saml_request(
          idp_signin_url,
          idp.use_redirect_for_req,
          req_xml_frag,
          relay_state |> URI.encode_www_form()
        )
    end
  end

  def send_signout_req(conn, state \\ Application.get_env(:samly, :state_provider, State.Ets)) do
    %IdpData{id: idp_id} = idp = conn.private[:samly_idp]
    %IdpData{esaml_idp_rec: idp_rec, esaml_sp_rec: sp_rec} = idp
    sp = ensure_sp_uris_set(sp_rec, conn)

    target_url = (conn.params["target_url"] || "/") |> URI.decode_www_form()

    case state.get(conn,"samly_assertion") do
      {_, %Assertion{idp_id: ^idp_id, authn: authn, subject: subject}} ->
        session_index = Map.get(authn, "session_index", "")
        subject_rec = Subject.to_rec(subject)

        {idp_signout_url, req_xml_frag} =
          Helper.gen_idp_signout_req(sp, idp_rec, subject_rec, session_index)

        relay_state = State.gen_id()

        conn
        |> state.delete("samly_assertion")
        |> put_session("target_url", target_url)
        |> put_session("relay_state", relay_state)
        |> put_session("idp_id", idp_id)
        |> send_saml_request(
          idp_signout_url,
          idp.use_redirect_for_req,
          req_xml_frag,
          relay_state |> URI.encode_www_form()
        )

      _ ->
        conn |> send_resp(403, "access_denied")
    end
  end
end
